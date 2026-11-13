{- | The effect shell of @state@: read the worktree, git and GitHub, decide
in pure code, then append to the log and print. Every decision is the
kernel's; this module moves data between them and the outside.
-}
module State.Shell (main, hook) where

import Control.Applicative ((<|>))
import Control.Exception (IOException, try)
import Control.Monad ((>=>))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Either (fromRight)
import Data.Foldable (traverse_)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8Lenient)
import Data.Text.IO qualified as Text
import Data.Time (UTCTime, getCurrentTime)
import Numeric (showHex)
import Numeric.Natural (Natural)
import State.Advice (Action (AwaitAnswer, Triage), Advice (..), Facts, advise, deliver, due, ownAsk)
import State.Advice qualified as Advice
import State.Ask (Principal (..), Question (..), oneLineText, qidText)
import State.Ask qualified as Ask
import State.Cap (stateNameText)
import State.Cli (Block (..), Command (..), Exit (..), Failure (..), InitArgs (..), Raise (..), Recording (..), RunCommand (..), explain, failureText, help, noteOf, parseCommand)
import State.Codec (LineError (..), LogError (..), decodeLine, eventType, logOf, reasonText)
import State.Event (AgentRole (..), Asker (..), Asking (..), Envelope (..), Event (..), FlowName (..), Note (..), RunId, SessionId (..), Sha, Source (..), Start (..), parseRunId, roleText, runIdText)
import State.Event qualified as Event
import State.Flows.Engineer (engineer)
import State.Flows.TenX (tenX)
import State.Fold (Append (..), Pending (asking), RunState (..), askedAt, nextQId, replay)
import State.Fold qualified as Fold
import State.Graph (Node (..), OpenGraph, graph)
import State.Handback (Handback (..), Typed (..), parseHandback, typeHandback)
import State.Handback qualified as Handback
import State.Hook (Call (..), Want (..), awaitingUser, callOf, encodeReply, hookName, hookSources, loggedAlready, offAdvice, parseHookEvent, parseHookName, replyOf, silent, toldOf, wants)
import State.Mode (Mode (..), Quality (Balanced), Size (Normal))
import State.Render qualified as Render
import State.Render.Mermaid (mermaid)
import State.Shell.Log (locked, readPointer, writePointer)
import State.Shell.Repo (gitDir, headBranch, headSha, prView, readFacts)
import State.Show (tshow)
import State.Steps (Steps, parseSteps)
import State.View (brief, pendingLines, showRun)
import System.Directory (createDirectoryIfMissing, doesFileExist, makeAbsolute, withCurrentDirectory)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.IO (IOMode (ReadMode), stderr, withBinaryFile)

-- | Run one command from argv; a failure goes to stderr with its exit code.
main :: [Text] -> IO ()
main argv = do
    (sub, result) <-
        loadSteps >>= \case
            Left failure -> pure ("steps", Left failure)
            Right steps -> do
                let (sub, parsed) = parseCommand steps argv
                result <- either (pure . Left) (outageAware . execute steps) parsed
                pure (sub, result)
    case result of
        Right out -> Text.putStr out
        Left failure -> do
            Text.hPutStr stderr (failureText sub failure)
            exitWith $ case failure.exit of
                BadInput -> ExitFailure 2
                Outage -> ExitFailure 1

{- | @state-hook <name>@: one hook event on stdin, its reply on stdout. Bad
usage or stdin exits 2; past that it never fails the agent: a worktree with no
run it reads is silence, a refusal or an error is context (fail open and tell).
-}
hook :: [Text] -> LBS.ByteString -> IO ()
hook argv input = case parseHookName argv of
    Nothing -> usage ("usage: state-hook " <> Text.intercalate " | " (map hookName [minBound .. maxBound]))
    Just name -> case parseHookEvent input of
        Left why -> usage ("state-hook " <> hookName name <> ": " <> why)
        Right event ->
            loadSteps >>= \case
                Left failure -> Text.hPutStr stderr (failureText ("hook " <> hookName name) failure) >> exitWith (ExitFailure 1)
                Right steps -> case wants steps name event of
                    Left why -> usage why
                    Right Nothing -> pure ()
                    Right (Just want) -> do
                        let call = callOf event
                        said <- try (withCurrentDirectory call.cwd (hookAnswer steps call want))
                        traverse_ LBS.putStr . encodeReply $ case said of
                            Right text -> replyOf want text
                            Left (e :: IOException) -> toldOf want ("state hook " <> hookName name <> ": " <> tshow e)
  where
    usage line = Text.hPutStrLn stderr line >> exitWith (ExitFailure 2)

-- | What the run says to a hook's want, recording what it must; empty when silent, a failure as its text.
hookAnswer :: Steps -> Call -> Want -> IO Text
hookAnswer steps call want =
    hasRun >>= \case
        False -> pure ""
        True -> case want of
            ResumeRun -> do
                -- Read before the lock, as @state next@ does: GitHub may take its whole timeout.
                (facts, told) <- readFacts
                onHook facts.pr $ \stamp run -> let (new, _, out) = adviceOf steps facts told stamp run in (new, showRun run.state <> out)
            SpawnRole spawned -> do
                (facts, told) <- readFacts
                onHook facts.pr $ \stamp run ->
                    let (new, action, out) = adviceOf steps facts told stamp run
                        warning = case (action, spawned) of
                            (Advice.Spawn advised, Just role) -> offAdvice steps run.state.at advised role
                            _ -> Nothing
                     in (new, out <> foldMap (<> "\n") warning)
            HandedBack _ message agent role ->
                branchPr >>= \pr -> onHook pr $ \stamp run ->
                    let sources = hookSources run.state.run agent role message
                     in if loggedAlready run.logged sources
                            then ([], "")
                            else either (failureText "handback") (Text.unlines . map ("state: " <>) . Text.lines) <$> record stamp run sources (handbackPlan steps stamp.head run.state role Nothing message)
            AskedUser -> branchPr >>= \pr -> onHook pr $ \_ run -> ([], Text.unlines (awaitingUser run.state))
  where
    -- A run that is over, bound to another branch or whose PR is merged or closed is
    -- silent too; the hook's session stamps its lines.
    onHook pr act = do
        branch <- headBranch
        result <- onRun $ \stamp run ->
            if silent branch ((.readiness) <$> pr) run.logged run.state
                then ([], Right "")
                else Right <$> act (Stamp stamp.ts stamp.head (Just (SessionId call.session))) run
        pure (either (failureText "hook") id result)
    -- GitHub unread is no PR: the hook speaks.
    branchPr = fromRight Nothing <$> prView
    -- A log of another version is the Python state's, which the hooks leave be (#360).
    hasRun =
        gitDir >>= \case
            Left _ -> pure False
            Right gd -> readPointer gd >>= maybe (pure False) (fmap ours . firstLine . logOf)
    ours = \case
        Nothing -> False
        Just line -> case decodeLine line of
            Left (Unsupported _) -> False
            Left (Malformed _) -> True
            Right _ -> True

-- | A disk or process error is the outage exit, never a crash.
outageAware :: IO (Either Failure Text) -> IO (Either Failure Text)
outageAware act =
    try act >>= \case
        Right result -> pure result
        Left (e :: IOException) -> pure (Left (Failure Outage "a disk or git failure" (tshow e) "retry once the disk and git work"))

-- | The flows' step table, which the installed @state@ names in @STATE_STEPS@.
loadSteps :: IO (Either Failure Steps)
loadSteps =
    lookupEnv "STATE_STEPS" >>= \case
        Nothing -> pure (Left (Failure Outage "STATE_STEPS is not set" "it names the flows' step table" "run the installed state, which sets it"))
        Just path -> do
            table <- LBS.readFile path
            pure $ case parseSteps table of
                Right steps -> Right steps
                Left whys -> Left (Failure Outage ("the step table " <> Text.pack path) (Text.intercalate "; " whys) "rebuild the installed state")

execute :: Steps -> Command -> IO (Either Failure Text)
execute steps = \case
    Help -> pure (Right (help steps))
    Render block flow -> pure (Right (rendered steps block flow))
    Init args -> inWorktree (`initRun` args)
    Next -> do
        -- Read before the lock: GitHub may take its whole timeout.
        (facts, told) <- readFacts
        onRun (\stamp run -> let (new, _, out) = adviceOf steps facts told stamp run in (new, Right out))
    HandbackOf role child -> do
        message <- Text.getContents
        onRun (\stamp run -> record stamp run (repeat Cli) (handbackPlan steps stamp.head run.state role child message))
    OnRun command -> onRun (\stamp run -> record stamp run (repeat Cli) (planOf steps stamp.head run.state command))

-- | What a command appends, and what it prints from the state reached and the lines written.
data Plan = Plan {events :: [Event], say :: RunState -> [Envelope] -> Text}

planOf :: Steps -> Maybe Sha -> RunState -> RunCommand -> Either Failure Plan
planOf steps worktreeHead state = \case
    Record (Plain event) -> Right (Plan [event] recordedLines)
    Record (AtHead event) -> case worktreeHead of
        Just sha -> Right (Plan [event sha] recordedLines)
        Nothing -> Left (Failure BadInput "no commit" "the event records HEAD and the worktree has none" "git commit")
    Override target why -> Right (Plan [Overridden target why] recordedLines)
    AskQuestion kind Itself text ->
        let (question, events, line) = ownAsk state kind text
         in Right (Plan events (\after _ -> asked question <> delivered after line))
    AskQuestion kind from text ->
        let question = Question (nextQId state) kind text
         in Right (Plan [Asked (Asking question (askedAt state) from)] (\after _ -> asked question <> delivered after (deliver after.start (Triage question))))
    RuleOn qid raise proposal -> Right (Plan (raised raise qid <> [RuledOn qid proposal]) (\_ _ -> "ruled " <> qidText qid <> "\n"))
    Forward qid raise ->
        Right . Plan (raised raise qid <> [Forwarded qid (Ask.deliver state.start.principal)]) $ \after _ ->
            "forwarded " <> qidText qid <> "\n" <> Text.concat [delivered after (deliver after.start (AwaitAnswer p.asking.question)) | p <- after.pending, p.asking.question.qid == qid]
    Answer qid answer by -> Right (Plan [Answered qid answer (fromMaybe (Ask.deliver state.start.principal) by)] (\_ _ -> "answered " <> qidText qid <> "\n"))
    StopRun stop -> Right (Plan [Event.Stopped stop] (\after _ -> "stopped\n" <> delivered after (deliver after.start (Advice.Stopped stop))))
    ShowRun -> Right (Plan [] (\_ _ -> showRun state))
    Pending -> Right (Plan [] (\_ _ -> Text.unlines (pendingLines state)))
    Brief role task -> Right (Plan [] (\_ _ -> brief steps state role task))
  where
    asked question = "asked " <> qidText question.qid <> "\n"
    raised raise qid = case raise of
        AsAsked -> []
        ToSecurity -> [RetaggedSecurity qid]

{- | A worker's hand-back as the run records it. One with no kind on its
question, or a worker's BLOCKED or FAILED, is the run's to triage.
-}
handbackPlan :: Steps -> Maybe Sha -> RunState -> AgentRole -> Maybe RunId -> Text -> Either Failure Plan
handbackPlan steps worktreeHead state role child message = do
    parsed <- unread (parseHandback message)
    typed <- unread (typeHandback steps state worktreeHead role parsed {Handback.run = parsed.run <|> child})
    Right (Plan typed.events (\after new -> recordedLines after new <> foldMap triage typed.untriaged))
  where
    unread = either (\why -> Left (Failure BadInput "the hand-back" why "state help")) Right
    triage line = "triage: " <> oneLineText line <> "\nfix: state ask --kind <kind> --from " <> roleText role <> " <question>\n"

{- | What @state next@ records and prints, and the advice's action: what GitHub
and the mode already decide is recorded first, then the advice: its line, the
last refusal until the next event, its facts indented, the step's lead and
entry text. The advice leads, so a refusal never reads as the next action.
-}
adviceOf :: Steps -> Facts -> [Text] -> Stamp -> Loaded -> ([Envelope], Action, Text)
adviceOf steps facts told stamp run = (new, advice.action, out)
  where
    (new, settled, unsynced) = settle run
    advice = advise steps facts settled.state
    out =
        recordedLines settled.state new
            <> delivered settled.state (deliver settled.state.start advice.action)
            <> foldMap (\note -> "refused: " <> note.message <> "\nfix: " <> note.fix <> "\n") settled.state.refused
            <> Text.concat ["  " <> line <> "\n" | line <- told <> unsynced <> advice.facts]
            <> (if Text.null advice.entry then "" else "\n" <> advice.entry <> "\n")
    settle current = case due current.g facts current.state of
        Nothing -> ([], current, [])
        Just outcome -> case commit stamp current [(Cli, Took outcome)] of
            -- Nobody asked for it, so it is told and not stored.
            Left refusal -> ([], current, ["PR sync refused: " <> (explain current.g (Fold.mode current.state) current.state.at refusal).why])
            Right (lines', after) -> let (more, final, notes) = settle after in (lines' <> more, final, notes)

-- | A hand-back line under a parent carries the run and its rulings (law Audit).
delivered :: RunState -> Text -> Text
delivered state line
    | "HANDBACK " `Text.isPrefixOf` line = Ask.handback line state.run state.rulings
    | otherwise = line <> "\n"

-- | A line per event written, each with where the run is now.
recordedLines :: RunState -> [Envelope] -> Text
recordedLines after = foldMap (\e -> "recorded " <> tshow e.seq <> " " <> eventType e.event <> " -> " <> stateNameText (askedAt after) <> "\n")

-- | The time, commit and session every line written now carries.
data Stamp = Stamp {ts :: UTCTime, head :: Maybe Sha, session :: Maybe SessionId}

-- | The run as replayed under the lock, and its log's lines, those this command wrote included.
data Loaded = Loaded {g :: OpenGraph, state :: RunState, logged :: NonEmpty Envelope}

{- | The lines for these events, each written by its source, in order, and the
run they reach, or the first refusal. An id already logged appends nothing.
-}
commit :: Stamp -> Loaded -> [(Source, Event)] -> Either Fold.Refusal ([Envelope], Loaded)
commit stamp = go []
  where
    go written run = \case
        [] -> Right (reverse written, run)
        (source, event) : rest -> do
            let envelope = stamped stamp source run.state.run (nextSeq run) event
            Fold.append run.g run.state envelope >>= \case
                Appended next -> go (envelope : written) run {state = next, logged = run.logged <> pure envelope} rest
                AlreadyLogged -> go written run rest

-- | The plan written by these sources, or its refusal logged so the next read warns of it.
record :: Stamp -> Loaded -> [Source] -> Either Failure Plan -> ([Envelope], Either Failure Text)
record stamp run sources = \case
    Left failure -> ([], Left failure)
    Right plan -> case commit stamp run (zip sources plan.events) of
        Right (new, after) -> (new, Right (plan.say after.state new))
        Left refusal ->
            let failure = explain run.g (Fold.mode run.state) run.state.at refusal
             in ([stamped stamp Cli run.state.run (nextSeq run) (Refused (noteOf failure))], Left failure)

-- | Lines are numbered from 1 in the order written, @started@ first.
nextSeq :: Loaded -> Natural
nextSeq run = fromIntegral (length run.logged) + 1

stamped :: Stamp -> Source -> RunId -> Natural -> Event -> Envelope
stamped stamp source run n event = Envelope {source, seq = n, ts = stamp.ts, run, head = stamp.head, session = stamp.session, event}

-- | The worktree's run, locked for one command.
onRun :: (Stamp -> Loaded -> ([Envelope], Either Failure a)) -> IO (Either Failure a)
onRun act =
    inWorktree $
        readPointer >=> \case
            Nothing -> pure (Left noRun)
            Just notes -> do
                let path = logOf notes
                exists <- doesFileExist path
                if not exists
                    then pure (Left noRun)
                    else do
                        stamp <- now
                        locked path $ \case
                            Left bad -> pure ([], Left (unreadLine path bad))
                            Right [] -> pure ([], Left noRun)
                            Right (first : rest) ->
                                let g = graphOf (flowOf first)
                                 in pure $ case replay g (first :| rest) of
                                        -- Balanced Normal, the mode until recorded: only what and why are read.
                                        Left refusal -> ([], Left (unreplayed path (explain g (Mode Balanced Normal) Out refusal)))
                                        Right state -> act stamp (Loaded g state (first :| rest))
  where
    noRun = Failure BadInput "no run in this worktree" "no state init ran here" "state init --notes /tmp/engineer-<owner>-<repo>-<slug>"

-- | The flow a log's first line starts; a log that starts no run is refused by its replay.
flowOf :: Envelope -> FlowName
flowOf first = case first.event of
    Started start -> start.flow
    _ -> EngineerFlow

{- | @state init@: idempotent, as a retried brief runs it again. A child names
its parent's log, which is checked to hold that run before this one starts.
-}
initRun :: FilePath -> InitArgs -> IO (Either Failure Text)
initRun gd args =
    principalOf args.parent >>= \case
        Left failure -> pure (Left failure)
        Right principal -> do
            notes <- makeAbsolute args.notes
            createDirectoryIfMissing True notes
            stamp <- now
            fresh <- newRunId
            let path = logOf notes
                start = Start {flow = args.flow, notes, principal, interface = interfaceOf principal, task = args.task}
            result <- locked path $ \case
                Left bad -> pure ([], Left (unreadLine path bad))
                Right [] -> pure ([stamped stamp Cli fresh 1 (Started start)], Right fresh)
                Right (first : rest) -> pure ([], joined notes (first :| rest))
            traverse (\run -> writePointer gd notes >> pure ("started " <> runIdText run <> "\n")) result
  where
    -- A subagent has no hooks, wakes, notifications or background of its own (#351 s4).
    interfaceOf = \case
        ByUser -> Set.fromList [minBound .. maxBound]
        ByRole _ _ -> Set.empty

{- | The run a retried init joins: the one its log holds. One log holds one
run, so a run stopped there leaves the dir to no other.
-}
joined :: FilePath -> NonEmpty Envelope -> Either Failure RunId
joined notes logged@(first :| _) = case (.stopped) <$> replay (graphOf (flowOf first)) logged of
    Right (Just stop) ->
        Left (Failure BadInput ("--notes " <> Text.pack notes) ("its run " <> runIdText first.run <> " stopped: " <> reasonText stop.reason <> " " <> stop.why) "state init --notes <a new dir>")
    Right Nothing -> Right first.run
    -- A log that does not replay is named by next and show; init leaves it be.
    Left _ -> Right first.run

{- | Who starts the run. A parent's log path was checked by the parser; here
its first line must be that run's start.
-}
principalOf :: Maybe (RunId, FilePath) -> IO (Either Failure Principal)
principalOf = \case
    Nothing -> pure (Right ByUser)
    Just (parent, path) -> do
        first <- firstLine path
        pure $ case decodeLine (fromMaybe "" first) of
            Right envelope | envelope.run == parent, Started _ <- envelope.event -> Right (ByRole parent path)
            _ -> Left (Failure BadInput ("--parent " <> runIdText parent) (Text.pack path <> " does not start that run") "state brief engineer, in the parent's worktree, prints the init line")

-- | A file's first line, if the file exists.
firstLine :: FilePath -> IO (Maybe Text)
firstLine path =
    doesFileExist path >>= \case
        False -> pure Nothing
        True -> Just . Text.takeWhile (/= '\n') . decodeUtf8Lenient <$> withBinaryFile path ReadMode (`BS.hGet` 65536)

inWorktree :: (FilePath -> IO (Either Failure a)) -> IO (Either Failure a)
inWorktree act = gitDir >>= either (pure . Left) act

now :: IO Stamp
now = Stamp <$> getCurrentTime <*> headSha <*> (fmap (SessionId . Text.pack) . nonEmpty <$> lookupEnv "STATE_SESSION")
  where
    nonEmpty = (>>= \s -> if null s then Nothing else Just s)

-- | Short and random: eight hex digits from the kernel's entropy.
newRunId :: IO RunId
newRunId = do
    bytes <- withBinaryFile "/dev/urandom" ReadMode (`BS.hGet` 4)
    let hex = Text.pack (concatMap (\b -> (if b < 16 then ('0' :) else id) (showHex b "")) (BS.unpack bytes))
    maybe (ioError (userError "a hex run id did not parse")) pure (parseRunId hex)

unreadLine :: FilePath -> LogError -> Failure
unreadLine path bad = Failure BadInput (Text.pack path <> " line " <> tshow bad.line <> " is not read") why ("repair or move " <> Text.pack path)
  where
    why = case bad.why of
        Unsupported v -> "log version " <> tshow v <> ", this state reads 3"
        Malformed what -> what

-- | A log whose lines read but whose events the flow refuses: edited by hand.
unreplayed :: FilePath -> Failure -> Failure
unreplayed path refusal = Failure BadInput (Text.pack path <> " does not replay") (refusal.what <> " - " <> refusal.why) ("repair or move " <> Text.pack path)

rendered :: Steps -> Block -> FlowName -> Text
rendered steps block flow = case block of
    States -> Render.states g steps
    QualityRows -> Render.quality
    Mermaid -> mermaid g
    TrivialSkips -> Render.trivialSkips g
    Kinds -> Render.kinds
    StopRule -> Render.stopRule
    PlanWrong -> Render.planWrong
  where
    g = graphOf flow

-- | Each flow's graph glues, as its test holds: a clash here is a bug.
graphOf :: FlowName -> OpenGraph
graphOf =
    either (error . ("the flow does not glue: " <>) . show) id . \case
        EngineerFlow -> graph engineer
        TenXFlow -> graph tenX
