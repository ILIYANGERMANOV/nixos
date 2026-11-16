{- | The effect shell of @state@: read the worktree, git and GitHub, decide
in pure code, then append to the log and print. Every decision is the
kernel's; this module moves data between them and the effects, whose IO
interpreters 'runShellIO' runs.
-}
module State.Cli.Shell (Shell, main, hook, runShellIO) where

import Control.Applicative ((<|>))
import Control.Exception (IOException)
import Control.Monad qualified as Monad
import Data.Bifunctor qualified as Bifunctor
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Either (fromRight)
import Data.Foldable (toList, traverse_)
import Data.Functor (($>), (<&>))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, maybeToList)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8, decodeUtf8', decodeUtf8Lenient, encodeUtf8)
import Data.Time (UTCTime)
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Exception (throwIO, try)
import Effects.Clock (Clock, runClockIO)
import Effects.Clock qualified as Clock
import Effects.Console (Console, runConsoleIO)
import Effects.Console qualified as Console
import Effects.Environment (Environment, lookupEnv, runEnvironmentIO)
import Effects.FileSystem (RoFileSystem, WrFileSystem, runFileSystemIO)
import Effects.FileSystem qualified as FileSystem
import Effects.Gh (Gh, runGhIO)
import Effects.Gh qualified as Gh
import Effects.Git (Git, runGitIO)
import Effects.Git qualified as Git
import Effects.Log (Log, runLogIO)
import Effects.Log qualified as Log
import Effects.Random (Random, randomBytes, runRandomIO)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Options.Applicative qualified as Opt
import State.Category.Fuel (Fuel (Balanced))
import State.Category.Graph (Node (..), OpenGraph, graph)
import State.Category.Step (stateNameText)
import State.Cli.Command (Block (..), Command (..), Exit (..), Failure (..), InitArgs (..), Raise (..), RunCommand (..), Usage (..), answeredQid, anyEvent, defaultFlow, explain, failureText, help, notStarted, noteOf, openQid, optparseText, parseCommand, parseHook, unknownEvent)
import State.Cli.Render qualified as Render
import State.Cli.Render.Mermaid (mermaid)
import State.Cli.Route (StateCall (..), route, stateCalls)
import State.Cli.View (beginText, brief, pendingLines, showRun)
import State.Protocol.Advice (Action (AwaitAnswer, Triage), Advice (..), Facts (..), PullRequest (..), advise, changedLinesOf, deliver, deliverPrompt, due, explained, ownAsk, pullRequestOf, skippable)
import State.Protocol.Advice qualified as Advice
import State.Protocol.Binding (AgentId (..), Binding (..), Key (..), Slot, Worktree (..), bindingFile, bindingIn, renderBinding, resolve, slotOf, staleNote, stashFile, storeRoot)
import State.Protocol.Handback (Handback (..), Typed (..), parseHandback, typeHandback)
import State.Protocol.Handback qualified as Handback
import State.Protocol.Hook (Bind (..), Call (..), Delivery (..), HookName (HandbackHook), Job (..), Reply (..), Want (..), aboutKnown, aboutRun, awaitingUser, callOf, delivery, encodeReply, followedAt, hookName, hookSources, keyOf, loggedAlready, offAdvice, parseHookEvent, replyOf, restartOf, silent, spawnedAt, toldOf, wants)
import State.Protocol.Hook qualified as Hook
import State.Protocol.Record (Recording (..))
import State.Role (RoleDef (..))
import State.Role qualified as Role
import State.Run.Ask (Above (ParentRun), Parent (..), Principal (..), QId, Question (..), oneLineText, qidText)
import State.Run.Ask qualified as Ask
import State.Run.Codec (LineError (..), LogError (..), decodeLine, eventType, logOf, reasonText, taskIdText)
import State.Run.Codec qualified as Codec
import State.Run.Event (AgentRole (..), Asker (..), Asking (..), Child (..), DraftPr (..), Envelope (..), Event (..), FlowName (..), Note (..), RunId, SessionId (..), Sha, Source (..), Start (..), Task (..), parseRunId, roleText, runIdText)
import State.Run.Event qualified as Event
import State.Run.Fan qualified as Fan
import State.Run.Fold (Append (..), Pending (asking), RunState (..), askedAt, nextQId, replay)
import State.Run.Fold qualified as Fold
import State.Run.Id (digestOf)
import State.Show (tshow)
import State.Step.Artifact (shellPathText, shellWord)
import State.Table (Steps, parseSteps)
import System.Exit (ExitCode (..))
import System.FilePath (equalFilePath, takeDirectory, (</>))

-- | Every effect the shell runs on.
type Shell es = (Clock :> es, Console :> es, Environment :> es, Gh :> es, Git :> es, Log :> es, Random :> es, RoFileSystem :> es, WrFileSystem :> es)

-- | A shell program against the real world: the process, its files, git and GitHub.
runShellIO :: Eff '[Random, Log, Git, Gh, WrFileSystem, RoFileSystem, Environment, Console, Clock, IOE] a -> IO a
runShellIO = runEff . runClockIO . runConsoleIO . runEnvironmentIO . runFileSystemIO . runGhIO . runGitIO . runLogIO . runRandomIO

-- | Run one command from argv; a failure goes to stderr with its exit code.
main :: (Shell es) => [Text] -> Eff es ExitCode
main argv =
    loadSteps >>= \case
        Left failure -> failed "steps" failure
        Right steps -> case parseCommand steps argv of
            Left said -> usageOut "state" said
            Right (sub, parsed) ->
                either (pure . Left) (outageAware . execute steps) parsed >>= \case
                    Right out -> Console.out out $> ExitSuccess
                    Left failure -> failed sub failure
  where
    failed sub failure =
        Console.err (failureText sub failure) $> case failure.exit of
            BadInput -> ExitFailure 2
            Outage -> ExitFailure 1

-- | Help asked for goes to stdout, exit 0; a usage error to stderr, exit 2.
usageOut :: (Console :> es) => String -> Usage -> Eff es ExitCode
usageOut program (Usage failure) = case Opt.renderFailure failure program of
    (text, ExitSuccess) -> Console.out (optparseText text) $> ExitSuccess
    (text, ExitFailure _) -> Console.err (optparseText text) $> ExitFailure 2

{- | @state-hook <name>@: one hook event on stdin, its reply on stdout. Bad
usage or stdin exits 2; past that it never fails the agent: a worktree with no
run it reads is silence, a refusal or an error is context (fail open and tell).
-}
hook :: (Shell es) => [Text] -> Eff es ExitCode
hook argv = case parseHook argv of
    Left said -> usageOut "state-hook" said
    Right name -> do
        input <- Console.readStdin
        case parseHookEvent (LBS.fromStrict input) of
            Left why -> usage ("state-hook " <> hookName name <> ": " <> why)
            Right event ->
                loadSteps >>= \case
                    Left failure -> Console.err (failureText ("hook " <> hookName name) failure) $> ExitFailure 1
                    Right steps -> case wants steps name event of
                        Left why -> usage why
                        Right Nothing -> pure ExitSuccess
                        Right (Just job) -> do
                            said <- try (jobReply steps name input (callOf event) job)
                            -- aeson encodes UTF-8, so the reply decodes whole.
                            traverse_ (Console.out . decodeUtf8 . LBS.toStrict) . encodeReply $ case said of
                                Right reply -> reply
                                Left e -> toldOf job (hookError name e)
                            pure ExitSuccess
  where
    usage line = Console.err (line <> "\n") $> ExitFailure 2

{- | A hook's reply to its job: how work begins needs no run; a route
denies a @state@ call at another run than the caller's; the rest is what the
caller's run says. A disk or git error is context naming the run once one is
known: the bound one, then the one found. One before either, such as reading
the caller's binding, names none, as no run is known yet.
-}
jobReply :: (Shell es) => Steps -> HookName -> BS.ByteString -> Call -> Job -> Eff es Reply
jobReply steps name input call job = case job of
    Begins begin -> pure (replyOf job (beginText steps begin))
    Routes command -> case stateCalls steps call.cwd command of
        [] -> pure Quiet
        calls ->
            readBound call >>= traverse standing >>= \case
                Just (bound, Standing) -> maybe Quiet Deny . route bound <$> traverse (\c -> (c,) <$> toplevelAt c.dir) calls
                -- A removed worktree's run is done: no call strays from it.
                Just (_, Removed) -> pure Quiet
                Nothing -> pure Quiet
    Asks want -> callerBinding call >>= \(slot, bound) -> replyOf job <$> telling name ((.run) <$> bound) (wantAnswer steps name input call want slot bound)
    Binds bind -> callerBinding call >>= \(slot, bound) -> replyOf job <$> telling name ((.run) <$> bound) (bindAnswer steps name call bind slot bound)

-- | What an act says; a disk or git error is its text too, naming the run when one is known.
telling :: HookName -> Maybe RunId -> Eff es Text -> Eff es Text
telling name run act = try act <&> either (aboutKnown run . hookError name) id

-- | A disk or git error a hook tells as context: it never fails the agent.
hookError :: HookName -> IOException -> Text
hookError name e = "state hook " <> hookName name <> ": " <> tshow e

-- | The caller's binding; none for an unbound caller or without a store.
readBound :: (Environment :> es, RoFileSystem :> es) => Call -> Eff es (Maybe Binding)
readBound call = snd <$> callerBinding call

-- | The caller's slot in the session's bindings, and the binding it holds.
callerBinding :: (Environment :> es, RoFileSystem :> es) => Call -> Eff es (Maybe Slot, Maybe Binding)
callerBinding call = do
    slot <- slotFor call.session (keyOf call.agent)
    (slot,) <$> maybe (pure Nothing) readBinding slot

-- | A binding, and whether its worktree stands: git finds none there once it is removed.
standing :: (Git :> es, RoFileSystem :> es) => Binding -> Eff es (Binding, Worktree)
standing binding = (binding,) . maybe Removed (const Standing) <$> toplevelAt binding.toplevel

-- | The top of the git worktree a directory is in; none for one in no worktree, or no directory.
toplevelAt :: (Git :> es, RoFileSystem :> es) => FilePath -> Eff es (Maybe FilePath)
toplevelAt dir =
    try (FileSystem.inDirectory dir Git.toplevel) <&> \case
        Right (Right top) -> Just top
        Right (Left _) -> Nothing
        Left (_ :: IOException) -> Nothing

-- | What a want says at the run its caller is bound to ("State.Protocol.Binding"), or where it waits ('delivery').
wantAnswer :: (Shell es) => Steps -> HookName -> BS.ByteString -> Call -> Want -> Maybe Slot -> Maybe Binding -> Eff es Text
wantAnswer steps name input call want slot bound = case delivery want (keyOf call.agent) slot bound of
    Stash at -> do
        -- Stashed before the binding is read again, as the spawner's hook binds before it
        -- reads the stash: whichever runs second sees the other's file.
        writeWhole (stashFile at) (decodeUtf8Lenient input)
        readBinding at >>= maybe (pure "") (replayStash steps name at)
    ToRun -> atRun steps name call want bound

-- | A bind: the caller to the run its init printed, or a worker it spawned to the caller's run.
bindAnswer :: (Shell es) => Steps -> HookName -> Call -> Bind -> Maybe Slot -> Maybe Binding -> Eff es Text
bindAnswer steps name call bind slot bound = case bind of
    BindSelf binding -> telling name (Just binding.run) ("" <$ traverse_ (`writeBinding` binding) slot)
    BindChild child role -> do
        -- The spawner's binding as it is: a stale one is told at the worker's hand-back.
        spawner <- case bound of
            Just binding -> pure (Just binding)
            Nothing -> Monad.join <$> traverse runHere (resolve (keyOf call.agent) Nothing call.cwd)
        childSlot <- slotFor call.session (AgentKey child)
        case (spawner, childSlot) of
            (Just binding, Just at) -> telling name (Just binding.run) $ do
                writeBinding at binding
                stashed <- replayStash steps name at binding
                pure (aboutRun binding.run ("state: " <> roleText role <> " " <> child.agentIdText <> " works in this run\n") <> stashed)
            _ -> pure ""

{- | The hand-back stashed in a worker's slot, recorded in the run it is bound
to now, then removed; nothing when none is. Recorded twice when both hooks
replay it at once, it is logged once ('loggedAlready').
-}
replayStash :: (Shell es) => Steps -> HookName -> Slot -> Binding -> Eff es Text
replayStash steps name slot binding =
    FileSystem.readText (stashFile slot) >>= \case
        Nothing -> pure ""
        Just stash -> do
            said <- case parseHookEvent (LBS.fromStrict (encodeUtf8 stash)) of
                Right event | Right (Just (Asks want)) <- wants steps HandbackHook event -> atRun steps name (callOf event) want (Just binding)
                _ -> pure (aboutRun binding.run ("state: the hand-back stashed at " <> Text.pack (stashFile slot) <> " is no hand-back of a step; removed\n"))
            FileSystem.removeFile (stashFile slot)
            pure said

-- | What the caller's run says to a want, in the worktree it resolves to; nothing when it has none.
atRun :: (Shell es) => Steps -> HookName -> Call -> Want -> Maybe Binding -> Eff es Text
atRun steps name call want bound = do
    worktree <- traverse standing bound
    case resolve (keyOf call.agent) worktree call.cwd of
        Nothing -> pure ""
        Just dir -> FileSystem.inDirectory dir (hookAnswer steps name call bound want)

-- | A key's slot in the session's bindings; none without a store root.
slotFor :: (Environment :> es) => SessionId -> Key -> Eff es (Maybe Slot)
slotFor session key = do
    root <- storeRoot <$> lookupEnv "XDG_STATE_HOME" <*> lookupEnv "HOME"
    pure (root >>= \at -> slotOf at session key)

-- | A slot's binding; a file that holds none is no binding.
readBinding :: (RoFileSystem :> es) => Slot -> Eff es (Maybe Binding)
readBinding slot = (>>= bindingIn) <$> FileSystem.readText (bindingFile slot)

writeBinding :: (WrFileSystem :> es) => Slot -> Binding -> Eff es ()
writeBinding slot binding = writeWhole (bindingFile slot) (renderBinding binding <> "\n")

-- | A file of the bindings' store, whole, as hooks of one session may run at once.
writeWhole :: (WrFileSystem :> es) => FilePath -> Text -> Eff es ()
writeWhole path text = do
    FileSystem.createDirectory (takeDirectory path)
    FileSystem.writeTextAtomic path text

{- | The run the worktree at this directory holds, as its init printed it:
the session's own agent, unbound, spawns into it.
-}
runHere :: (Shell es) => FilePath -> Eff es (Maybe Binding)
runHere dir =
    FileSystem.inDirectory dir $
        pointedRun >>= \case
            Just (notes, Right started) -> either (const Nothing) (Just . Binding started.run notes) <$> Git.toplevel
            Just (_, Left _) -> pure Nothing
            Nothing -> pure Nothing

-- | The run the worktree's pointer names: its notes dir and its log's first line, decoded; none without either.
pointedRun :: (Git :> es, Log :> es, RoFileSystem :> es) => Eff es (Maybe (FilePath, Either LineError Envelope))
pointedRun =
    gitDir >>= \case
        Left _ -> pure Nothing
        Right gd ->
            readPointer gd >>= \case
                Nothing -> pure Nothing
                Just notes -> fmap ((notes,) . decodeLine) <$> Log.firstLine (logOf notes)

{- | What the worktree's run says to a hook's want, naming it, a disk or git
error too. A log of another log version, as an older one, the hooks leave be
(#360); one whose first line does not read names no run but the bound one.
-}
hookAnswer :: (Shell es) => Steps -> HookName -> Call -> Maybe Binding -> Want -> Eff es Text
hookAnswer steps name call bound want =
    pointedRun >>= \case
        Nothing -> pure ""
        Just (_, Left (Unsupported _)) -> pure ""
        Just (_, Left (Malformed _)) -> at ((.run) <$> bound)
        Just (_, Right started) -> at (Just started.run)
  where
    at found = telling name found (runAnswer steps call bound found want)

-- | What the run found says to a hook's want, recording what it must; empty when silent, a failure as its text.
runAnswer :: (Shell es) => Steps -> Call -> Maybe Binding -> Maybe RunId -> Want -> Eff es Text
runAnswer steps call bound found want = case want of
    ResumeRun source -> do
        -- Read before the lock, as @state next@ does: GitHub may take its whole timeout.
        (facts, told) <- readFacts
        onHook facts.pr $ \stamp run -> case commit stamp run [(Cli, event) | event <- maybeToList (restartOf source run.state)] of
            Left refusal -> ([], failureText "resume" (explain run.g (Fold.fuelOf run.state) run.state.at run.state.meters refusal))
            Right (restart, after) ->
                let (new, _, out) = adviceOf steps facts told stamp after
                 in (restart <> new, recordedLines after.state restart <> showRun after.g after.state <> out.text)
    SpawnRole spawned -> do
        (facts, told) <- readFacts
        onHook facts.pr $ \stamp run ->
            -- At a choice, the spawn of an action's worker opens a child; elsewhere it records nothing.
            case commit stamp run [(Cli, event) | Just role <- [spawned], Just event <- [spawnedAt steps run.state.at role]] of
                Left refusal -> ([], failureText "spawn" (explain run.g (Fold.fuelOf run.state) run.state.at run.state.meters refusal))
                Right (opened, after) ->
                    let (new, action, out) = adviceOf steps facts told stamp after
                        warning = case (action, spawned) of
                            (Advice.Spawn advised _, Just role) -> offAdvice steps after.state.at advised role
                            _ -> Nothing
                     in (opened <> new, recordedLines after.state opened <> out.text <> foldMap (<> "\n") warning)
    Hook.HandedBack message agent role ->
        branchPr >>= \pr -> onHook pr $ \stamp run ->
            let sources = hookSources run.state.run agent role message
             in if loggedAlready run.logged sources || not (followedAt run.state.at role)
                    then ([], "")
                    else either (failureText "handback") (Text.unlines . map ("state: " <>) . Text.lines . (.text)) <$> record stamp run sources (handbackPlan steps stamp.head run.state role Nothing message)
    AskedUser -> branchPr >>= \pr -> onHook pr $ \_ run -> ([], Text.unlines (awaitingUser run.state))
  where
    -- A run that is over, bound to another branch or whose PR is merged or closed is
    -- silent too; the hook's session stamps its lines, and its text names the run.
    onHook pr act = do
        branch <- Git.headBranch
        result <- onRun $ \stamp run -> case bound >>= (`staleNote` run.state.run) of
            Just note -> ([], Right note)
            Nothing
                | silent branch ((.readiness) <$> pr) run.logged run.state -> ([], Right "")
                | otherwise -> Right . aboutRun run.state.run <$> act (Stamp stamp.ts stamp.head (Just call.session)) run
        pure (either (aboutKnown found . failureText "hook") id (orNoRun result))
    -- GitHub unread is no PR: the hook speaks.
    branchPr = fromRight Nothing . pullRequestOf <$> Gh.prView

-- | A disk or process error is the outage exit, never a crash.
outageAware :: Eff es (Either Failure Text) -> Eff es (Either Failure Text)
outageAware act =
    try act >>= \case
        Right result -> pure result
        Left (e :: IOException) -> pure (Left (Failure Outage "a disk or git failure" (tshow e) "retry once the disk and git work"))

-- | The flows' step table, which the installed @state@ names in @STATE_STEPS@.
loadSteps :: (Environment :> es, RoFileSystem :> es) => Eff es (Either Failure Steps)
loadSteps =
    lookupEnv "STATE_STEPS" >>= \case
        Nothing -> pure (Left (Failure Outage "STATE_STEPS is not set" "it names the flows' step table" "run the installed state, which sets it"))
        Just path -> do
            table <- FileSystem.readBytes path
            pure $ case parseSteps (LBS.fromStrict table) of
                Right steps -> Right steps
                Left whys -> Left (Failure Outage ("the step table " <> Text.pack path) (Text.intercalate "; " whys) "rebuild the installed state")

execute :: (Shell es) => Steps -> Command -> Eff es (Either Failure Text)
execute steps = \case
    Help -> pure (Right (help steps))
    Render block flow -> pure (Right (rendered steps block flow))
    Init args -> inWorktree (`initRun` args)
    Next -> do
        -- Read before the lock: GitHub may take its whole timeout.
        (facts, told) <- readFacts
        orNoRun <$> handingBack steps (\stamp run -> let (new, _, out) = adviceOf steps facts told stamp run in (new, Right out))
    HandbackOf role child -> do
        input <- Console.readStdin
        case decodeUtf8' input of
            Left _ -> pure (Left (Failure BadInput "the hand-back" "stdin is not UTF-8" "state help"))
            Right message -> fmap (.text) . orNoRun <$> onRun (\stamp run -> record stamp run (repeat Cli) (handbackPlan steps stamp.head run.state role child message))
    OnRun command -> do
        -- Read before the lock, as GitHub is.
        file <- traverse FileSystem.readText (fileOf command)
        handingBack steps (\stamp run -> record stamp run (repeat Cli) (planOf steps stamp.head (Monad.join file) run.g run.state command)) <&> \case
            -- With no run, nothing says where the run is: every event is named.
            NoRun | RecordUnknown name <- command -> Left (anyEvent name)
            NoRun -> Left noRun
            Ran result -> result
  where
    fileOf = \case
        Record recording -> case recording of
            FromFile path _ -> Just path
            Plain _ -> Nothing
            AtHead _ -> Nothing
        RecordUnknown _ -> Nothing
        Brief _ _ -> Nothing
        ShowRun -> Nothing
        Override _ _ -> Nothing
        AskQuestion {} -> Nothing
        RuleOn {} -> Nothing
        Forward _ _ -> Nothing
        Answer {} -> Nothing
        StopRun _ -> Nothing
        Pending -> Nothing

-- | What a command appends, and what it prints from the state reached and the lines written.
data Plan = Plan {events :: [Event], say :: RunState -> [Envelope] -> Output}

-- | What a command prints, the hand-back it delivers, and the answer it writes down, if any.
data Output = Output {text :: Text, handback :: Maybe Text, down :: Maybe Down}

instance Semigroup Output where
    Output a first firstDown <> Output b second secondDown = Output (a <> b) (first <|> second) (firstDown <|> secondDown)

instance Monoid Output where
    mempty = Output "" Nothing Nothing

-- | Text that delivers no hand-back.
printed :: Text -> Output
printed text = Output text Nothing Nothing

-- | The answer to the question, written down to the child that asked it, if one did.
writtenDown :: RunState -> QId -> Output
writtenDown state qid = Output "" Nothing (downOf state qid)

-- | A line per event written, delivering no hand-back.
recorded :: RunState -> [Envelope] -> Output
recorded after = printed . recordedLines after

-- | The file a recording reads, read beforehand: 'Nothing' when it does not exist.
planOf :: Steps -> Maybe Sha -> Maybe Text -> OpenGraph -> RunState -> RunCommand -> Either Failure Plan
planOf steps worktreeHead file g state = \case
    Record (Plain event) -> Right (Plan [event] recorded)
    Record (AtHead event) -> case worktreeHead of
        Just sha -> Right (Plan [event sha] recorded)
        Nothing -> Left (Failure BadInput "no commit" "the event records HEAD and the worktree has none" "git commit")
    Record (FromFile path parse) -> case parse <$> file of
        Just (Right event) -> Right (Plan [event] recorded)
        Just (Left why) -> Left (Failure BadInput (Text.pack path) why "fix the file")
        Nothing -> Left (Failure BadInput (Text.pack path) "no such file" "write it first")
    Override target why -> Right (Plan [Overridden target why] recorded)
    AskQuestion kind Itself text ->
        let (question, events, line) = ownAsk state kind text
         in Right (Plan events (\after _ -> asked question <> delivered after line))
    AskQuestion kind from text ->
        let question = Question (nextQId state) kind text
         in Right (Plan [Asked (Asking question (askedAt state) from)] (\after _ -> asked question <> delivered after (deliver after.start (Triage question))))
    RecordUnknown name -> Left (unknownEvent g state name)
    RuleOn raw raise proposal -> open raw >>= \qid -> Right (Plan (raised raise qid <> [RuledOn qid proposal]) (\after _ -> printed ("ruled " <> qidText qid <> "\n") <> writtenDown after qid))
    Forward raw raise ->
        open raw >>= \qid -> Right . Plan (raised raise qid <> [Forwarded qid (Ask.deliver state.start.principal)]) $ \after _ ->
            printed ("forwarded " <> qidText qid <> "\n") <> mconcat [delivered after (deliver after.start (AwaitAnswer p.asking.question)) | p <- after.pending, p.asking.question.qid == qid]
    Answer raw answer by -> answeredQid state raw >>= \qid -> Right (Plan [Answered qid answer (fromMaybe (Ask.deliver state.start.principal) by)] (\after _ -> printed ("answered " <> qidText qid <> "\n") <> writtenDown after qid))
    StopRun stop -> Right (Plan [Event.Stopped stop] (\after _ -> printed "stopped\n" <> delivered after (deliver after.start (Advice.Stopped stop))))
    ShowRun -> Right (Plan [] (\_ _ -> printed (showRun g state)))
    Pending -> Right (Plan [] (\_ _ -> printed (Text.unlines (pendingLines state))))
    Brief role task -> case brief steps state role task of
        Left unknown -> Left (Failure BadInput ("task " <> taskIdText unknown) "the breakdown has no such task" "state show")
        Right text -> Right (Plan [] (\_ _ -> printed text))
  where
    open = openQid state
    asked question = printed ("asked " <> qidText question.qid <> "\n")
    raised raise qid = case raise of
        AsAsked -> []
        ToSecurity -> [RetaggedSecurity qid]

{- | A worker's hand-back as the run records it. One with no kind on its
question, or a worker's BLOCKED or FAILED, is the run's to triage.
-}
handbackPlan :: Steps -> Maybe Sha -> RunState -> AgentRole -> Maybe RunId -> Text -> Either Failure Plan
handbackPlan steps worktreeHead state role child message = do
    parsed <- unread (parseHandback message)
    let run = parsed.run <|> child
    typed <- unread (typeHandback steps state worktreeHead role parsed {Handback.run = run})
    let from = maybe (roleText role) runIdText run
        triage line = "triage: " <> oneLineText line <> "\nfix: state ask --kind <kind> --from " <> from <> " <question>\n"
    Right (Plan typed.events (\after new -> printed (recordedLines after new <> foldMap triage typed.untriaged)))
  where
    unread = either (\why -> Left (Failure BadInput "the hand-back" why "state help")) Right

{- | What @state next@ records and prints, and the advice's action: what GitHub
and the run's Fuel already decide is recorded first, then the advice: its line, the
last refusal until the next event, its facts indented, the step's lead and
task text. The advice leads, so a refusal never reads as the next action;
under it, where the run is and each option, one per line.
-}
adviceOf :: Steps -> Facts -> [Text] -> Stamp -> Loaded -> ([Envelope], Action, Output)
adviceOf steps facts told stamp run = (new, advice.action, out)
  where
    (new, settled, unsynced) = settle run
    advice = advise steps settled.g facts settled.state
    out =
        recorded settled.state new
            <> delivered settled.state (deliver settled.state.start advice.action)
            <> printed
                ( foldMap (\note -> "refused: " <> note.message <> "\nfix: " <> note.fix <> "\n") settled.state.refused
                    <> Text.concat ["  " <> line <> "\n" | line <- explained settled.state.start advice <> told <> unsynced <> advice.facts <> skippable settled.g settled.state]
                    <> (if Text.null advice.prompt then "" else "\n" <> deliverPrompt settled.state.start advice <> "\n")
                )
    settle current = case due current.g facts current.state of
        Nothing -> ([], current, [])
        Just event -> case commit stamp current [(Cli, event)] of
            -- Nobody asked for it, so it is told and not stored.
            Left refusal -> ([], current, ["PR sync refused: " <> (explain current.g (Fold.fuelOf current.state) current.state.at current.state.meters refusal).why])
            Right (lines', after) -> let (more, final, notes) = settle after in (lines' <> more, final, notes)

-- | A hand-back line under a parent carries the run and its rulings (law Audit), and is delivered.
delivered :: RunState -> Text -> Output
delivered state line
    | "HANDBACK " `Text.isPrefixOf` line = let handback = Ask.handback line state.run state.rulings in Output handback (Just handback) Nothing
    | otherwise = printed (line <> "\n")

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
record :: Stamp -> Loaded -> [Source] -> Either Failure Plan -> ([Envelope], Either Failure Output)
record stamp run sources = \case
    Left failure -> ([], Left failure)
    Right plan -> case commit stamp run (zip sources plan.events) of
        Right (new, after) -> (new, Right (plan.say after.state new))
        Left refusal ->
            let failure = explain run.g (Fold.fuelOf run.state) run.state.at run.state.meters refusal
             in ([stamped stamp Cli run.state.run (nextSeq run) (Refused (noteOf failure))], Left failure)

-- | Lines are numbered from 1 in the order written, @started@ first.
nextSeq :: Loaded -> Natural
nextSeq run = fromIntegral (length run.logged) + 1

stamped :: Stamp -> Source -> RunId -> Natural -> Event -> Envelope
stamped stamp source run n event = Envelope {source, seq = n, ts = stamp.ts, run, head = stamp.head, session = stamp.session, event}

{- | 'onRun' for a command that may hand back or answer. A hand-back it
delivers under a parent is recorded in the parent's run too, and an answer
it gives is written down to the child that asked, once this run's lock is
released, as init's spawn is ('spawnedIn').
-}
handingBack :: (Shell es) => Steps -> (Stamp -> Loaded -> ([Envelope], Either Failure Output)) -> Eff es (Ran Text)
handingBack steps act =
    onRun (\stamp run -> let (new, result) = act stamp run in (new, (\out -> (out.text, upOf run new =<< out.handback, out.down)) <$> result)) >>= \case
        NoRun -> pure NoRun
        Ran (Left failure) -> pure (Ran (Left failure))
        Ran (Right (text, up, down)) -> do
            above <- maybe (pure "") (handedUp steps) up
            below <- maybe (pure "") answeredDown down
            pure (Ran (Right (text <> above <> below)))

{- | A child run's hand-back to its parent: the parent, the child's run, its
role, what makes the hand-back one, and the text.
-}
data Up = Up {parent :: Parent, child :: RunId, role :: AgentRole, once :: Text, text :: Text}

{- | A question is handed up once, whatever the child's log grew by since,
as @state next@ delivers it again until its answer comes; any other
hand-back once per line of the child's log, so a CI awaited again after a
resume is news.
-}
upOf :: Loaded -> [Envelope] -> Text -> Maybe Up
upOf run new text = case run.state.start.principal of
    ByUser -> Nothing
    ByRole parent _ -> Just (Up parent run.state.run (Role.role run.state.start.flow).name once text)
  where
    once = maybe (tshow (nextSeq run - 1 + fromIntegral (length new))) qidText (asks =<< either (const Nothing) (.token) (parseHandback text))
    asks = \case
        Handback.NeedsDecision (Handback.Asks question) -> Just question.qid
        Handback.NeedsDecision (Handback.StuckOn _) -> Nothing
        Handback.NeedsDecision (Handback.PlanWrong _) -> Nothing
        Handback.NeedsDecision (Handback.Untyped _) -> Nothing
        Handback.Ready _ -> Nothing
        Handback.Await _ _ -> Nothing
        Handback.Blocked _ -> Nothing
        Handback.Failed _ -> Nothing

{- | The child's hand-back, appended to its parent's log under the parent's
lock by ids hashed from the child's run and what makes the hand-back one: a
repeated command appends it once. The ids alone skip only events typed alike: typed again
against a parent that moved on, a repeat would refuse or add others. A refusal or an outage does not fail the child's command,
which tells it; the parent's @state next@ names a child that ended unrecorded.
-}
handedUp :: (Shell es) => Steps -> Up -> Eff es Text
handedUp steps up =
    try (onLog append up.parent.log) <&> \case
        Right (Right ()) -> ""
        Right (Left failure) -> told (failure.what <> " - " <> failure.why)
        Left (e :: IOException) -> told (tshow e)
  where
    sources = [Hook (digestOf [runIdText up.child, up.once, tshow n]) | n <- [0 :: Int ..]]
    append stamp run
        | loggedAlready run.logged sources = ([], Right ())
        | otherwise = case record stamp run sources (handbackPlan steps stamp.head run.state up.role (Just up.child) up.text) of
            -- The child tells its refusal; the parent's log does not keep it.
            (_, Left failure) -> ([], Left failure)
            (new, Right _) -> (new, Right ())
    told why = "parent: " <> why <> "\nfix: hand back as printed; the parent's state next catches it\n"

{- | An answer on its way down: the run that holds it, the child that asked
it of that run, the question and its answer.
-}
data Down = Down {above :: RunId, child :: Child, qid :: QId, answer :: Text}

-- | The answer the run holds to the question, for the child of its fan-out that asked it.
downOf :: RunState -> QId -> Maybe Down
downOf state qid = do
    asker <- Fan.askedBy (Fold.currentFan state) qid
    answer <- lookup qid (Fold.given state)
    Just (Down state.run asker.child qid answer)

{- | The answer, appended to the asking child's log under its lock by ids
hashed from both runs and the question, so a retry appends it once; then on
down from that child, to the run that asked it first. A refusal or an
outage below does not fail the answer, which tells it with the command that
writes it there by hand.
-}
answeredDown :: (Shell es) => Down -> Eff es Text
answeredDown down =
    try (onLog write down.child.log) >>= \case
        Right (Right below) -> maybe (pure "") answeredDown (downOf below down.qid)
        Right (Left failure) -> pure (told (failure.what <> " - " <> failure.why))
        Left (e :: IOException) -> pure (told (tshow e))
  where
    source = Hook (digestOf [runIdText down.above, qidText down.qid, runIdText down.child.run])
    write stamp run = case commit stamp run [(source, Answered down.qid down.answer (ParentRun down.above))] of
        Right (new, after) -> (new, Right after.state)
        -- The answering run tells the refusal; the child's log does not keep it.
        Left refusal -> ([], Left (explain run.g (Fold.fuelOf run.state) run.state.at run.state.meters refusal))
    told why =
        "child "
            <> runIdText down.child.run
            <> ": "
            <> why
            <> "\nfix: state answer "
            <> qidText down.qid
            <> " "
            <> shellWord down.answer
            <> " --by "
            <> runIdText down.above
            <> ", in "
            <> Text.pack down.child.worktree
            <> "\n"

-- | The worktree's run, locked for one command.
onRun :: (Clock :> es, Environment :> es, Git :> es, Log :> es, RoFileSystem :> es) => (Stamp -> Loaded -> ([Envelope], Either Failure a)) -> Eff es (Ran a)
onRun act =
    gitDir >>= \case
        Left failure -> pure (Ran (Left failure))
        Right gd -> readPointer gd >>= maybe (pure NoRun) (onRunLog act . logOf)

-- | The run this log holds, locked for one command.
onLog :: (Clock :> es, Environment :> es, Git :> es, Log :> es) => (Stamp -> Loaded -> ([Envelope], Either Failure a)) -> FilePath -> Eff es (Either Failure a)
onLog act path = orNoRun <$> onRunLog act path

onRunLog :: (Clock :> es, Environment :> es, Git :> es, Log :> es) => (Stamp -> Loaded -> ([Envelope], Either Failure a)) -> FilePath -> Eff es (Ran a)
onRunLog act path =
    Log.exists path >>= \case
        False -> pure NoRun
        True -> do
            stamp <- now
            Log.locked path $ \case
                Left bad -> ([], Ran (Left (unreadLine path bad)))
                Right [] -> ([], NoRun)
                Right (first : rest) -> case replayed path (first :| rest) of
                    Left failure -> ([], Ran (Left failure))
                    Right (g, state) -> Ran <$> act stamp (Loaded g state (first :| rest))

-- | A run command's outcome: no run to command, or the command's own.
data Ran a = NoRun | Ran (Either Failure a)

orNoRun :: Ran a -> Either Failure a
orNoRun = \case
    NoRun -> Left noRun
    Ran result -> result

noRun :: Failure
noRun = Failure BadInput "no run in this worktree" "no state init ran here" "state init --notes /tmp/engineer-<owner>-<repo>-<slug>"

-- | A log replayed under the flow its first line starts.
replayed :: FilePath -> NonEmpty Envelope -> Either Failure (OpenGraph, RunState)
replayed path logged@(first :| _) = case Fold.runStart first.event of
    Nothing -> Left (unreplayed path notStarted)
    Just start ->
        let g = graphOf start.flow
         in -- Balanced, the Fuel until recorded: only what and why are read.
            either (Left . unreplayed path . explain g Balanced Out Map.empty) (Right . (g,)) (replay g logged)

{- | @state init@: idempotent, as a retried brief runs it again. A child names
its parent's log, which is checked to hold that run before this one starts.
A worktree holds one run: init refuses to start one over the unfinished run
the worktree's pointer names in another notes dir.

On success it prints two lines, the second the interface a hook parses:

> started <id>            (or: resumed <id>)
> run <id> <notes> <top>

Space separated; @<notes>@ is the run's notes dir and @<top>@ the worktree's
top, both absolute. The parser refuses whitespace in a notes dir; @<top>@
comes last and is the rest of the line, as git may name a path with spaces.
-}
initRun :: (Shell es) => FilePath -> InitArgs -> Eff es (Either Failure Text)
initRun gd args = do
    -- Every read before the first write, the first refusal told.
    free <- unfinishedHere gd notes
    began <- startOf args
    top <- worktreeTop
    case (,,) <$> free <*> began <*> top of
        Left failure -> pure (Left failure)
        Right ((), Begin {principal, flow, fuel}, worktree) -> do
            FileSystem.createDirectory notes
            stamp <- now
            fresh <- newRunId
            let path = logOf notes
                start = Start {flow, notes = notes, principal, interface = interfaceOf principal}
                begun = Started start : map FuelSet (toList fuel)
            result <- Log.locked path $ \case
                Left bad -> ([], Left (unreadLine path bad))
                Right [] -> (zipWith (stamped stamp Cli fresh) [1 ..] begun, Right ("started", fresh))
                Right (first : rest) -> ([], ("resumed",) <$> joined notes (first :| rest))
            -- The pointer only once the parent took the child: a refused child has no run here.
            accepted <- case (result, args.parent) of
                (Right said@(_, run), Just parent) -> fmap (const said) <$> spawnedIn parent.run parent.log (Child run parent.task path worktree)
                (Right said, Nothing) -> pure (Right said)
                (Left failure, _) -> pure (Left failure)
            traverse (\(verb, run) -> writePointer gd notes $> initLines verb run worktree) accepted
  where
    notes = shellPathText args.notes
    -- A subagent has no wakes, notifications or background of its own (#351 s4). Hooks
    -- run in it, but a child's hand-back is its own state's to record in the parent.
    interfaceOf = \case
        ByUser -> Set.fromList [minBound .. maxBound]
        ByRole _ _ -> Set.empty
    initLines verb run worktree = Text.unlines [verb <> " " <> runIdText run, renderBinding (Binding run notes worktree)]

-- | The worktree's top, which a child's @spawned@ and init's @run@ line name.
worktreeTop :: (Git :> es) => Eff es (Either Failure FilePath)
worktreeTop = Bifunctor.first (\why -> Failure BadInput "not inside a git work tree" why "cd <worktree>") <$> Git.toplevel

{- | Refuses a start in this notes dir while the worktree's pointer names an
unfinished run in another: the fix resumes that run or stops it. A run that
ended, or whose log is gone or does not read or replay, holds the worktree no
more.
-}
unfinishedHere :: (Shell es) => FilePath -> FilePath -> Eff es (Either Failure ())
unfinishedHere gd notes =
    readPointer gd >>= \case
        Nothing -> pure (Right ())
        Just held
            -- A pointer an older init wrote may end in a separator.
            | equalFilePath held notes -> pure (Right ())
            | otherwise -> holding held <$> onLog (\_ run -> ([], Right run.state)) (logOf held)
  where
    holding held = \case
        Left _ -> Right ()
        Right state -> case liveness state of
            Ended _ -> Right ()
            Live ->
                Left
                    ( Failure
                        BadInput
                        ("--notes " <> Text.pack notes)
                        ("the worktree holds unfinished run " <> runIdText state.run <> " in " <> Text.pack held)
                        ("state init --notes " <> Text.pack held <> " resumes it, or state stop <reason> <why> ends it")
                    )

{- | The child's @spawned@, appended to its parent's log under the parent's
lock, by an id hashed from both runs: a retried init appends it once.
-}
spawnedIn :: (Shell es) => RunId -> FilePath -> Child -> Eff es (Either Failure ())
spawnedIn parent parentLog child =
    Monad.void <$> onLog (\stamp run -> record stamp run [source] (Right (Plan [Spawned child] (\_ _ -> mempty)))) parentLog
  where
    source = Hook (digestOf [runIdText parent, runIdText child.run])

{- | The run a retried init joins: the one its log holds. One log holds one
run, so a run stopped or finished there leaves the dir to no other: a 10x's
next round gives its engineer a fresh one.
-}
joined :: FilePath -> NonEmpty Envelope -> Either Failure RunId
joined notes logged@(first :| _) = case liveness . snd <$> replayed (logOf notes) logged of
    Right (Ended why) -> Left (Failure BadInput ("--notes " <> Text.pack notes) ("its run " <> runIdText first.run <> " " <> why) "state init --notes <a new dir>")
    Right Live -> Right first.run
    -- A log that does not replay is named by next and show; init leaves it be.
    Left _ -> Right first.run

-- | Whether a run goes on, or how it ended.
data Liveness = Live | Ended Text

liveness :: RunState -> Liveness
liveness state = case (state.stopped, Fold.over state) of
    (Just stop, _) -> Ended ("stopped: " <> reasonText stop.reason <> " " <> stop.why)
    (Nothing, True) -> Ended "finished"
    (Nothing, False) -> Live

-- | Who starts a run, its flow, and the Fuel already set: a child's task sets it, a user's run asks.
data Begin = Begin {principal :: Principal, flow :: FlowName, fuel :: Maybe Fuel}

{- | Who starts the run, and its flow: a child runs its task's flow, at its
task's Fuel, the task read from the parent's log.
-}
startOf :: (Shell es) => InitArgs -> Eff es (Either Failure Begin)
startOf args = case args.parent of
    Nothing -> pure (Right (Begin ByUser (fromMaybe defaultFlow args.flow) Nothing))
    Just parent ->
        parentStarts parent >>= \case
            Left failure -> pure (Left failure)
            Right () -> onLog (\_ run -> ([], childStart parent args.flow run.state)) parent.log

{- | A parent's log path was checked by the parser; here its first line must
be that run's start.
-}
parentStarts :: (Log :> es) => Parent -> Eff es (Either Failure ())
parentStarts parent = do
    first <- Log.firstLine parent.log
    pure $ case decodeLine (fromMaybe "" first) of
        Right envelope | envelope.run == parent.run, Started _ <- envelope.event -> Right ()
        _ -> Left (Failure BadInput ("--parent " <> runIdText parent.run) (Text.pack parent.log <> " does not start that run") initLineFix)

-- | The child's principal, with its task's shape, its flow and its Fuel.
childStart :: Parent -> Maybe FlowName -> RunState -> Either Failure Begin
childStart parent named state = do
    task <- childTask parent state
    flow <- childFlow named task
    Right (Begin (ByRole parent task.shape) flow (Just task.fuel))

-- | The parent's task the child runs: the parent must be at a fan-out whose breakdown names it.
childTask :: Parent -> RunState -> Either Failure Task
childTask parent state = case (Fold.fanAt state.at, Fan.lookupTask (Fold.currentFan state) parent.task) of
    (Nothing, _) -> Left (Failure BadInput ("--parent " <> runIdText parent.run) "its run is at no fan-out whose children run a flow" "state show, in the parent's worktree")
    (Just _, Nothing) -> Left (Failure BadInput ("--task " <> taskIdText parent.task) "the parent's breakdown has no such task" initLineFix)
    (Just _, Just task) -> Right task

-- | The task's flow; a @--flow@ named must be that one.
childFlow :: Maybe FlowName -> Task -> Either Failure FlowName
childFlow named task = case named of
    Nothing -> Right task.flow
    Just asked
        | asked == task.flow -> Right asked
        | otherwise ->
            Left
                ( Failure
                    BadInput
                    ("--flow " <> Codec.flowText asked)
                    ("task " <> taskIdText task.id <> " runs the " <> Codec.flowText task.flow <> " flow")
                    ("state brief " <> Codec.flowText task.flow <> " --task " <> taskIdText task.id <> ", in the parent's worktree, prints the init line")
                )

initLineFix :: Text
initLineFix = "state brief engineer, in the parent's worktree, prints the init line"

inWorktree :: (Git :> es) => (FilePath -> Eff es (Either Failure a)) -> Eff es (Either Failure a)
inWorktree act = gitDir >>= either (pure . Left) act

now :: (Clock :> es, Environment :> es, Git :> es) => Eff es Stamp
now = Stamp <$> Clock.now <*> Git.headSha <*> (fmap (SessionId . Text.pack) . nonEmpty <$> lookupEnv "STATE_SESSION")
  where
    nonEmpty = (>>= \s -> if null s then Nothing else Just s)

-- | Short and random: eight hex digits from the kernel's entropy.
newRunId :: (Random :> es) => Eff es RunId
newRunId = do
    bytes <- randomBytes 4
    let hex = Text.pack (concatMap (\b -> (if b < 16 then ('0' :) else id) (showHex b "")) (BS.unpack bytes))
    maybe (throwIO (userError "a hex run id did not parse")) pure (parseRunId hex)

{- | An older state's log (Python's versions 1 and 2) is not migrated: its
run is set aside and a fresh one started in its place.
-}
unreadLine :: FilePath -> LogError -> Failure
unreadLine path bad = Failure BadInput (Text.pack path <> " line " <> tshow bad.line <> " is not read") why fix
  where
    notes = Text.pack (takeDirectory path)
    (why, fix) = case bad.why of
        Unsupported v ->
            ( "log version " <> tshow v <> ", this state reads " <> tshow Codec.version
            , "move the old run aside and start fresh: mv " <> notes <> " " <> notes <> ".old, then state init --notes " <> notes
            )
        Malformed what -> (what, "repair or move " <> Text.pack path)

-- | A log whose lines read but whose events the flow refuses: edited by hand.
unreplayed :: FilePath -> Failure -> Failure
unreplayed path refusal = Failure BadInput (Text.pack path <> " does not replay") (refusal.what <> " - " <> refusal.why) ("repair or move " <> Text.pack path)

rendered :: Steps -> Block -> FlowName -> Text
rendered steps block flow = case block of
    States -> Render.states g steps
    FuelRows -> Render.fuel g
    Mermaid -> mermaid g
    Kinds -> Render.kinds
    StopRule -> Render.stopRule
    PlanWrong -> Render.planWrong
  where
    g = graphOf flow

-- | Each flow's graph glues, as its test holds: a clash here is a bug.
graphOf :: FlowName -> OpenGraph
graphOf = either (error . ("the flow does not glue: " <>) . show) id . graph . (.flow) . Role.role

-- | The worktree's git dir, where the pointer to its run lives.
gitDir :: (Git :> es) => Eff es (Either Failure FilePath)
gitDir = Bifunctor.first (\why -> Failure BadInput "not inside a git work tree" why "cd <worktree>; state keeps one run per worktree") <$> Git.gitDir

-- | The notes dir the worktree's run keeps, if a run was started here.
readPointer :: (RoFileSystem :> es) => FilePath -> Eff es (Maybe FilePath)
readPointer dir = fmap (Text.unpack . Text.strip) <$> FileSystem.readText (pointerOf dir)

writePointer :: (WrFileSystem :> es) => FilePath -> FilePath -> Eff es ()
writePointer dir notes = FileSystem.writeText (pointerOf dir) (Text.pack notes <> "\n")

-- | A pointer file in the git dir names the notes dir, which holds @events.jsonl@.
pointerOf :: FilePath -> FilePath
pointerOf dir = dir </> "state-notes"

{- | The branch's PR on GitHub and the lines it changes, each 'Nothing' when
it cannot be read, with a line saying why, and the children that ended.
-}
readFacts :: (Shell es) => Eff es (Facts, [Text])
readFacts = do
    reply <- Gh.prView
    ended <- endedChildren
    case pullRequestOf reply of
        Left why -> pure (Facts Nothing Nothing ended, ["PR sync skipped - " <> why])
        Right Nothing -> pure (Facts Nothing Nothing ended, [])
        Right (Just pr) ->
            Git.numstat pr.draft.base >>= \case
                Right out -> pure (Facts (Just (changedLinesOf out)) (Just pr) ended, [])
                Left why -> pure (Facts Nothing (Just pr) ended, ["changed lines unknown - " <> why])

{- | The children the worktree's run counts running whose own log shows their
run over, each log read under its lock in turn. A log that does not read
counts as running; the run's own failure is its command's to tell.
-}
endedChildren :: (Shell es) => Eff es [RunId]
endedChildren =
    onRun (\_ run -> ([], Right (map (.child) (Fan.running (Fold.currentFan run.state))))) >>= \case
        NoRun -> pure []
        Ran (Left _) -> pure []
        Ran (Right children) -> concat <$> traverse ended children
  where
    ended child = fromRight [] <$> onLog (\_ run -> ([], Right [child.run | Fold.over run.state])) child.log
