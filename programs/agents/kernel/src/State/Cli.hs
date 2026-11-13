{- | The @state@ command line (#360's CLI contract): argv parsed into a
'Command' before any effect, the usage text generated from the same tables,
and every failure in the shape the @/self-improve@ analyzer parses:
@state <sub>: what - why@, then @fix: <command>@.
-}
module State.Cli (
    Command (..),
    RunCommand (..),
    InitArgs (..),
    Recording (..),
    Raise (..),
    Block (..),
    Failure (..),
    Exit (..),
    parseCommand,
    failureText,
    noteOf,
    explain,
    notStarted,
    help,
    recordCommand,
) where

import Data.Bifunctor (first)
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Read (decimal)
import State.Ask (Above (..), Basis (..), Kind, OneLine, Proposal (..), QId, kindName, parseKind, parseOneLine, parseQId, qidText)
import State.Ask qualified as Ask
import State.Cap (EventName, Step (..), continueEvent, eventText, exitEvent, skipEvent, stateNameText)
import State.Codec (areaText, judgementText, logName, reasonText)
import State.Codec qualified as Codec
import State.Event (AgentRole (..), Asker (..), Branch (..), Check (..), Commit (..), DraftPr (..), Event (..), FlowName (..), Label (..), Note (..), Outcome (..), Picks (..), Requirement (..), RunId, Sha, StateName (..), Stop (..), TaskId (..), TaskState (..), Url (..), childRoles, parseRunId, roleText, runIdText)
import State.Fan qualified as Fan
import State.Flow (FanEvent (Leaves), FanId (FEngineers), fanEvent, fanName, loopName)
import State.Fold (Refusal (..), roundOnly)
import State.Graph (Arrow (..), Edge (..), Node (..), OpenGraph (..), Place (..), places)
import State.Handback (parseTouches)
import State.Id (parseEventId)
import State.Mode (Cfg (..), Mode, SkipWhen (Never), cfg, parseByName, parseQuality, qualityName, sizeName)
import State.Show (tshow)
import State.Steps (Steps, agentRoles)
import System.FilePath (isAbsolute, takeFileName)

data Command
    = Init InitArgs
    | -- | The hand-back on stdin, from this role, of this child run when it names none.
      HandbackOf AgentRole (Maybe RunId)
    | Next
    | Render Block FlowName
    | Help
    | OnRun RunCommand

-- | A command on the worktree's run, read and written under the log's lock.
data RunCommand
    = Record Recording
    | -- | The role's brief, and the task a child engineer runs.
      Brief AgentRole (Maybe Text)
    | ShowRun
    | Override StateName Text
    | -- | A question, the run's own or one a worker or child put to it.
      AskQuestion Kind Asker OneLine
    | RuleOn QId Raise Proposal
    | Forward QId Raise
    | -- | The answer that came down; by the run's principal unless named.
      Answer QId Text (Maybe Above)
    | StopRun Stop
    | Pending

data InitArgs = InitArgs
    { notes :: FilePath
    , flow :: FlowName
    , parent :: Maybe (RunId, FilePath)
    -- ^ The parent run and its log, as the parent's brief names them.
    , task :: Text
    }

{- | An event to record. Most carry the commit the worktree is at, which only
the shell can read; a breakdown is read from a file, by the shell too.
-}
data Recording = Plain Event | AtHead (Sha -> Event) | FromFile FilePath (Text -> Either Text Event)

-- | A question kept at its kind, or raised to 'Ask.Security' first.
data Raise = AsAsked | ToSecurity
    deriving stock (Eq, Show)

-- | What @state render@ prints: each a block the skills paste.
data Block = States | QualityRows | Mermaid | TrivialSkips | Kinds | StopRule | PlanWrong
    deriving stock (Eq, Show, Enum, Bounded)

{- | Why a command did nothing, as @state <sub>: what - why@ and a @fix:@
line naming the command to run instead.
-}
data Failure = Failure {exit :: Exit, what :: Text, why :: Text, fix :: Text}
    deriving stock (Eq, Show)

-- | Exit 2 for bad usage, a bad log line or a refused event; exit 1 for git or disk.
data Exit = BadInput | Outage
    deriving stock (Eq, Show)

failureText :: Text -> Failure -> Text
failureText sub failure = "state " <> sub <> ": " <> failure.what <> " - " <> failure.why <> "\nfix: " <> failure.fix <> "\n"

-- | A refusal as the log keeps it, for @next@ and @show@ to warn of.
noteOf :: Failure -> Note
noteOf failure = Note (failure.what <> " - " <> failure.why) failure.fix

-- | The subcommand, for the failure line, and the command or why it is not one.
parseCommand :: Steps -> [Text] -> (Text, Either Failure Command)
parseCommand steps = \case
    [] -> ("help", Right Help)
    sub : rest -> (sub, parseSub steps sub rest)

parseSub :: Steps -> Text -> [Text] -> Either Failure Command
parseSub steps sub rest = case sub of
    "init" -> withArgs ["notes", "flow", "parent", "parent-log", "task"] $ \a -> do
        none a
        notes <- required "notes" a
        flow <- maybe (Right EngineerFlow) (named "flow" (parseByName Codec.flowText)) (option "flow" a)
        parent <- case (option "parent" a, option "parent-log" a, option "task" a) of
            (Nothing, Nothing, _) -> Right Nothing
            (Just run, Just logPath, Just _) -> Just <$> ((,) <$> runId run <*> parentLog logPath)
            _ -> Left (usage "--parent, --parent-log and --task go together" "a child run names its parent's run and log, and its task")
        Right (Init InitArgs {notes = Text.unpack notes, flow, parent, task = fromMaybe "" (option "task" a)})
    "record" -> case rest of
        [] -> Left (usage "no event" "record names one event")
        name : args -> case [r | r <- recordables, r.name == name] of
            r : _ -> do
                a <- argsOf r.flags args
                OnRun . Record <$> first (\why -> Failure BadInput ("record " <> name) why ("state record " <> Text.strip (name <> " " <> r.args))) (r.parse a)
            [] -> Left (usage ("no event " <> name) ("one of " <> Text.unwords (map (.name) recordables)))
    "handback" -> withArgs ["child"] $ \a -> do
        role <- oneWord "role" a
        child <- traverse runId (option "child" a)
        HandbackOf <$> knownRole (agentRoles steps <> childRoles) role <*> pure child
    "next" -> bare Next
    "brief" -> withArgs ["task"] $ \a -> do
        role <- oneWord "role" a
        OnRun <$> (Brief <$> knownRole (agentRoles steps <> childRoles) role <*> pure (option "task" a))
    "show" -> bare (OnRun ShowRun)
    "override" -> withArgs [] $ \a -> case a.positional of
        target : why@(_ : _) -> Right (OnRun (Override (StateName target) (Text.unwords why)))
        _ -> Left (usage "override needs a state and why" "state override <state> <why>")
    "render" -> withArgs ["flow"] $ \a -> do
        block <- case a.positional of
            [] -> Right States
            [name] -> named "block" (parseByName blockName) name
            _ -> Left (usage "render takes one block" (Text.unwords (map blockName [minBound .. maxBound])))
        Render block <$> maybe (Right EngineerFlow) (named "flow" (parseByName Codec.flowText)) (option "flow" a)
    "ask" -> withArgs ["kind", "from"] $ \a -> do
        kind <- named "kind" parseKind =<< required "kind" a
        from <- maybe (Right Itself) (asker (agentRoles steps)) (option "from" a)
        OnRun . AskQuestion kind from <$> (oneLine =<< sentence "question" a)
    "rule" -> withArgs ["answer", "why", "cost", "basis", "raise"] $ \a -> do
        qid <- question a
        raise <- raising a
        proposal <-
            Proposal
                <$> (oneLine =<< required "answer" a)
                <*> (oneLine =<< required "why" a)
                <*> (oneLine =<< required "cost" a)
                <*> traverse basis (option "basis" a)
        Right (OnRun (RuleOn qid raise proposal))
    "forward" -> withArgs ["raise"] $ \a -> OnRun <$> (Forward <$> question a <*> raising a)
    "answer" -> withArgs ["by"] $ \a -> case a.positional of
        raw : answer@(_ : _) -> OnRun <$> (Answer <$> qidOf raw <*> pure (Text.unwords answer) <*> traverse above (option "by" a))
        _ -> Left (usage "answer needs a question id and the answer" "state answer <qid> <answer>")
    "stop" -> withArgs [] $ \a -> case a.positional of
        reason : why@(_ : _) -> (\r -> OnRun (StopRun (Stop r (Text.unwords why)))) <$> named "stop reason" (parseByName reasonText) reason
        _ -> Left (usage "stop needs a reason and why" ("state stop <" <> Text.intercalate "|" (map reasonText [minBound .. maxBound]) <> "> <why>"))
    "pending" -> bare (OnRun Pending)
    "help" -> bare Help
    other -> Left (usage ("no command " <> other) "see the commands state help lists")
  where
    withArgs allowed k = argsOf allowed rest >>= k
    bare command = withArgs [] $ \a -> none a >> Right command
    question a = case a.positional of
        [raw] -> qidOf raw
        _ -> Left (usage "one question id expected" "state pending lists them")
    raising a = case option "raise" a of
        Nothing -> Right AsAsked
        Just "security" -> Right ToSecurity
        Just other -> Left (usage ("--raise " <> other) "a question is only raised to security")
    basis raw = case Text.stripPrefix "obvious:" raw of
        Just why -> Obvious <$> oneLine (Text.strip why)
        Nothing -> maybe (Left (usage ("--basis " <> raw) "an event id such as r7f2:12, or obvious:<why>")) (Right . AnsweredBy) (parseEventId raw)
    above = \case
        "user" -> Right TheUser
        raw -> ParentRun <$> runId raw

-- | The usage failure, with @state help@ as the fix.
usage :: Text -> Text -> Failure
usage what why = Failure BadInput what why "state help"

-- | Positionals and @--name value@ options, the only kind of flag there is.
data Args = Args {positional :: [Text], options :: [(Text, Text)]}

argsOf :: [Text] -> [Text] -> Either Failure Args
argsOf allowed = \case
    [] -> Right (Args [] [])
    word : rest -> case Text.stripPrefix "--" word of
        Just name
            | name `notElem` allowed -> Left (usage ("--" <> name) ("not an option here; options: " <> optionList))
            | value : more <- rest -> (\a -> a {options = (name, value) : a.options}) <$> argsOf allowed more
            | otherwise -> Left (usage ("--" <> name) "needs a value")
        Nothing -> (\a -> a {positional = word : a.positional}) <$> argsOf allowed rest
  where
    optionList = if null allowed then "none" else Text.unwords (map ("--" <>) allowed)

-- | The last value given, as a shell user retyping an option expects.
option :: Text -> Args -> Maybe Text
option name a = case options name a of
    [] -> Nothing
    values -> Just (last values)

options :: Text -> Args -> [Text]
options name a = [value | (key, value) <- a.options, key == name]

required :: Text -> Args -> Either Failure Text
required name = maybe (Left (usage ("no --" <> name) ("--" <> name <> " is required"))) Right . option name

none :: Args -> Either Failure ()
none a = case a.positional of
    [] -> Right ()
    extra -> Left (usage (Text.unwords extra) "takes no positional argument")

oneWord :: Text -> Args -> Either Failure Text
oneWord what a = case a.positional of
    [word] -> Right word
    _ -> Left (usage ("one " <> what <> " expected") ("got " <> tshow (length a.positional)))

-- | Every positional word, joined: a shell user need not quote a sentence.
sentence :: Text -> Args -> Either Failure Text
sentence what a = case a.positional of
    [] -> Left (usage ("no " <> what) ("the " <> what <> " follows the options"))
    words' -> Right (Text.unwords words')

oneLine :: Text -> Either Failure OneLine
oneLine raw = maybe (Left (usage "a line break" "answers, reasons and questions are one line each")) Right (parseOneLine raw)

named :: Text -> (Text -> Maybe a) -> Text -> Either Failure a
named what parse raw = maybe (Left (usage ("no " <> what <> " " <> raw) ("see the " <> what <> "s state help lists"))) Right (parse raw)

runId :: Text -> Either Failure RunId
runId = named "run id" parseRunId

qidOf :: Text -> Either Failure QId
qidOf = named "question id" parseQId

knownRole :: [AgentRole] -> Text -> Either Failure AgentRole
knownRole roles raw
    | AgentRole raw `elem` roles = Right (AgentRole raw)
    | otherwise = Left (usage ("no role " <> raw) ("one of " <> Text.unwords (map roleText roles)))

{- | A role a step runs as, else a child run by its id: a run id never names a
role, which the step table spells in full.
-}
asker :: [AgentRole] -> Text -> Either Failure Asker
asker roles raw
    | AgentRole raw `elem` roles = Right (Subagent (AgentRole raw))
    | otherwise = ChildRun <$> runId raw

{- | A parent's log as its brief names it: an absolute path to an
@events.jsonl@, checked before anything there is opened.
-}
parentLog :: Text -> Either Failure FilePath
parentLog raw
    | isAbsolute path, takeFileName path == logName = Right path
    | otherwise = Left (usage ("--parent-log " <> raw) ("the parent's log is an absolute path to its " <> Text.pack logName))
  where
    path = Text.unpack raw

blockName :: Block -> Text
blockName = \case
    States -> "states"
    QualityRows -> "quality"
    Mermaid -> "mermaid"
    TrivialSkips -> "trivial"
    Kinds -> "kinds"
    StopRule -> "stop-rule"
    PlanWrong -> "plan-wrong"

{- | The full usage: every command, then every event @record@ takes, from
the same table its parser reads.
-}
help :: Steps -> Text
help steps =
    Text.unlines $
        ["usage: state <command> [args]", "", "commands:"]
            <> map ("  " <>) commands
            <> ["", "events (state record <event> [args]; a commit event records HEAD):"]
            <> ["  " <> Text.strip (r.name <> " " <> r.args) | r <- recordables]
            <> [ ""
               , "kinds: " <> choices kindName
               , "stop reasons: " <> choices reasonText
               , "roles: " <> Text.unwords (map roleText (agentRoles steps))
               , "areas (--touches): " <> choices areaText
               , ""
               , "Exit 0 ok; 2 bad usage, a bad log line or a refused event; 1 a git or disk failure."
               , "A failure prints `state <command>: what - why`, then `fix: <command>`."
               ]
  where
    commands =
        [ "init --notes <dir> [--flow " <> choices Codec.flowText <> "] [--parent <run> --parent-log <path>] [--task <id>]"
        , "record <event> [args]"
        , "handback <role> [--child <run>]     the hand-back on stdin"
        , "next                                the next action, its facts and the step's entry"
        , "brief <role> [--task <id>]"
        , "show"
        , "override <state> <why>"
        , "render [" <> choices blockName <> "] [--flow " <> choices Codec.flowText <> "]"
        , "ask --kind <kind> [--from <role|run>] <question>"
        , "rule <qid> --answer <a> --why <w> --cost <c> [--basis <event-id>|obvious:<why>] [--raise security]"
        , "forward <qid> [--raise security]"
        , "answer <qid> <answer> [--by user|<run>]"
        , "stop <reason> <why>"
        , "pending"
        , "help"
        ]

-- | The @state record@ line for an event, its arguments' usage after it.
recordCommand :: EventName -> Text
recordCommand event = Text.strip ("state record " <> name <> " " <> foldMap (.args) [r | r <- recordables, r.name == name])
  where
    name = eventText event

-- | An event @state record@ takes: its name, its arguments' usage, and their parser.
data Recordable = Recordable {name :: Text, args :: Text, flags :: [Text], parse :: Args -> Either Text Recording}

-- | Every event a lead records by hand, in the order a run meets them.
recordables :: [Recordable]
recordables =
    [ stay "quality" ("<" <> choices qualityName <> ">") $ \case
        [raw] -> QualitySet <$> known "quality" parseQuality raw
        _ -> Left "one quality"
    , stay "size" ("<" <> choices sizeName <> ">") $ \case
        [raw] -> SizeSet <$> known "size" (parseByName sizeName) raw
        _ -> Left "one size"
    , stay "grew" "<why>" (fmap Grew . because)
    , outcome (continueEvent Research) "<n>" [] $ \a -> case a.positional of
        [raw] -> Plain . Took . ResearchDone <$> count raw
        _ -> Left "the number of researchers"
    , nothing (skipEvent Research) ResearchSkipped
    , nothing (exitEvent Interview) InterviewEnough
    , nothing (continueEvent Interview) InterviewMore
    , outcome (continueEvent PlanS) "<path>" [] $ \a -> case a.positional of
        [path] -> Right (Plain (Took (PlanDone (Text.unpack path))))
        _ -> Left "the plan's path"
    , nothing (continueEvent SimplifyP) SimplifyPlanDone
    , nothing (skipEvent SimplifyP) SimplifyPlanSkipped
    , nothing (continueEvent Alternative) AlternativeDone
    , nothing (skipEvent Alternative) AlternativeSkipped
    , nothing (exitEvent Confirm) ConfirmConfirmed
    , nothing (continueEvent Confirm) ConfirmAdjusted
    , outcome (continueEvent Draft) "<url> <base> <branch>" [] $ \a -> case a.positional of
        [link, base, branch] -> Right (Plain (Took (DraftDone (DraftPr (Url link) (Branch base) (Branch branch)))))
        _ -> Left "the PR's url, base and branch"
    , -- As a hand-back with no Touches line reads: an implementer may have touched any area.
      commitAt (continueEvent Implement) ImplementDone (Set.fromList [minBound .. maxBound])
    , atHead (continueEvent Refactor) RefactorDone
    , outcome (skipEvent Refactor) "<why>" [] (fmap (Plain . Took . RefactorSkipped) . because . (.positional))
    , atHead (exitEvent Review) ReviewClean
    , atHead (continueEvent Review) ReviewRows
    , picks (exitEvent Pick) PickFinal
    , picks (continueEvent Pick) PickLoop
    , -- A fixer's hand-back with no Touches line touches no area.
      commitAt (continueEvent Fix) FixDone Set.empty
    , atHead (continueEvent Describe) DescribeDone
    , atHead (continueEvent SimplifyPR) SimplifyPrDone
    , atHead (skipEvent SimplifyPR) SimplifyPrSkipped
    , atHead (exitEvent AwaitCi) AwaitCiGreen
    , outcome (continueEvent AwaitCi) "<check>..." [] $ \a -> case a.positional of
        check : more -> Right (AtHead (\sha -> Took (AwaitCiRed sha (fmap Check (check :| more)))))
        [] -> Left "the failing checks"
    , atHead (continueEvent FixPR) FixPrDone
    , url (continueEvent Ready) ReadyDone
    , url (skipEvent Ready) ReadySkipped
    , outcome (continueEvent Breakdown) "--tasks <file.json>" ["tasks"] $ \a -> case (a.positional, option "tasks" a) of
        ([], Just path) -> Right (FromFile (Text.unpack path) (fmap (Took . BreakdownDone) . Codec.decodeBreakdown))
        _ -> Left "the tasks file, as --tasks <file.json>"
    , nothing (fanEvent Leaves (fanName FEngineers)) (FanDone FEngineers)
    , Recordable "task" ("<id> <ci|review|merged> <pr> | <id> parked <why> [--pr <url>]") ["pr"] $ \a -> case a.positional of
        [task, state, pr] | Just moved <- lookup state [("ci", InCi), ("review", InReview), ("merged", Merged)] -> Right (Plain (TaskMoved (TaskId task) (moved (Url pr))))
        task : "parked" : why@(_ : _) -> Right (Plain (TaskMoved (TaskId task) (Parked (Text.unwords why) (Url <$> option "pr" a))))
        _ -> Left "the task, then ci, review or merged and its PR, or parked and why"
    , stay "held" "<task> <url>" $ \case
        [task, link] -> Right (Held (TaskId task) (Url link))
        _ -> Left "the task and the url"
    , url (continueEvent Merge) MergeDone
    ]
  where
    stay name usageText build = Recordable name usageText [] (\a -> Plain <$> build a.positional)
    outcome event = Recordable (eventText event)
    nothing event done = outcome event "" [] $ \a -> case a.positional of
        [] -> Right (Plain (Took done))
        _ -> Left "no arguments"
    atHead event done = outcome event "" [] $ \a -> case a.positional of
        [] -> Right (AtHead (Took . done))
        _ -> Left "no arguments: the head is HEAD"
    commitAt event done unstated = outcome event "[--touches <area>,...|none]" ["touches"] $ \a -> case a.positional of
        [] -> (\areas -> AtHead (\sha -> Took (done (Commit sha areas)))) <$> maybe (Right unstated) parseTouches (option "touches" a)
        _ -> Left "no arguments: the head is HEAD"
    picks event done = outcome event ("[--row <label>]... [--verdict <requirement>=<" <> choices judgementText <> ">]...") ["row", "verdict"] $ \a -> case a.positional of
        [] -> Plain . Took . done . Picks (Set.fromList (map Label (options "row" a))) . Map.fromList <$> traverse verdict (options "verdict" a)
        _ -> Left "rows and verdicts are options"
    url event done = outcome event "<url>" [] $ \a -> case a.positional of
        [raw] -> Right (Plain (Took (done (Url raw))))
        _ -> Left "the PR's url"
    because = \case
        [] -> Left "why"
        why -> Right (Text.unwords why)
    count raw = case decimal raw of
        Right (n, "") -> Right n
        _ -> Left (raw <> " is not a count")
    verdict raw = case Text.breakOnEnd "=" raw of
        (requirement, judgement) | Just r <- Text.stripSuffix "=" requirement, not (Text.null r) -> (Requirement r,) <$> known "verdict" (parseByName judgementText) judgement
        _ -> Left (raw <> " is not <requirement>=<verdict>")
    known :: Text -> (Text -> Maybe a) -> Text -> Either Text a
    known what parse raw = maybe (Left ("no " <> what <> " " <> raw)) Right (parse raw)

choices :: (Bounded a, Enum a) => (a -> Text) -> Text
choices name = Text.intercalate "|" (map name [minBound .. maxBound])

-- | A log whose first line starts no run: it has no flow to explain against.
notStarted :: Failure
notStarted = Failure BadInput "the log" "its first line is not started" "state init --notes <dir>"

{- | A refusal of the fold, as the reader acts on it: what, why, and the
command to run instead, from the edges out of where the run is that the
run's mode would take.
-}
explain :: OpenGraph -> Mode -> Node -> Refusal -> Failure
explain g mode at = \case
    NotStarted -> notStarted
    StartedTwice -> refused "started" "the run has started already" "state next"
    OtherRun run -> refused "the line" ("it is run " <> runIdText run <> "'s, not this log's") "state show"
    AfterStop stop -> refused "the event" ("the run stopped: " <> reasonText stop.reason <> " " <> stop.why) "state init --notes <a new dir>"
    NoEdge _ event -> refused (eventText event) ("no such arrow out of " <> atText) (records taken)
    NotSkippable _ -> refused "the skip" "this mode never skips the step" (records (not . skips))
    OutOfFuel loop fuel ->
        refused
            ("another " <> loopName loop <> " round")
            ("the loop ran its " <> tshow fuel <> " rounds")
            (records (\edge -> edge.back /= Just loop && roundOnly g edge.to /= Just loop) <> " | state stop fuel <why>")
    QualitySetOnce quality -> refused "quality" ("it is " <> qualityName quality <> " already, set once") "state show"
    SizeSetOnce size -> refused "size" ("it is " <> sizeName size <> " already; only grew changes it") "state record grew <why>"
    NoSingleState (StateName name) ->
        refused ("override to " <> name) "the flow has no single state of that name" ("state override <" <> Text.intercalate "|" stateNames <> "> <why>")
    AskedTwice qid -> refused (qidText qid) "it was asked already" "state pending"
    NotPending qid -> refused (qidText qid) "no such question is pending" "state pending"
    AlreadyForwarded qid -> refused (qidText qid) "it was forwarded: only its answer is left" ("state answer " <> qidText qid <> " <answer>")
    NotForwarded qid -> refused (qidText qid) "it was never forwarded: this run rules on it or forwards it" (triage (qidText qid))
    NotAllowed refusal -> case refusal of
        Ask.MayNotRule _ kind -> refused ("a ruling on " <> kindName kind) ("this run forwards a " <> kindName kind <> " question") "state forward <qid>"
        Ask.MustAnswer _ kind -> refused ("a forward of " <> kindName kind) ("this run answers a " <> kindName kind <> " question itself") (triage "<qid>")
        Ask.NeverAskedOf _ kind -> refused (kindName kind) "such a question never reaches this run" "state pending"
        Ask.NoBasis qid -> refused ("a ruling on " <> qidText qid) "a Security ruling names its basis" (rule (qidText qid) <> " --basis <event-id>|obvious:<why>")
    NotAbove _ -> refused "the answer" "only whoever started the run answers it" "state answer <qid> <answer>"
    FanRefused refusal -> case refusal of
        Fan.UnknownTask task -> refused ("task " <> Codec.taskIdText task) "the breakdown has no such task" "state show"
        Fan.StillRunning task child -> refused ("a child for task " <> Codec.taskIdText task) ("child " <> runIdText child <> " still runs it") "state next"
        Fan.SpawnedTwice child -> refused ("child " <> runIdText child) "it was spawned already" "state next"
        Fan.UnknownChild child -> refused ("the hand-back of " <> runIdText child) "no such child was spawned" "state show"
        Fan.ChildOver child -> refused ("the hand-back of " <> runIdText child) "the child finished or stopped already" "state next"
        Fan.Unsettled tasks -> refused "the fan-out's end" ("tasks not settled: " <> Text.unwords (map Codec.taskIdText (toList tasks))) "state next"
  where
    refused = Failure BadInput
    atText = case at of
        At place -> stateNameText place.name
        Out -> "the end"
        Exit -> "the end"
    records keep = case at of
        At place -> case [recordCommand event | ((from, event), edge) <- Map.toList g.edges, from == place, keep edge] of
            [] -> "state show"
            commands -> Text.intercalate " | " commands
        Out -> "state show"
        Exit -> "state show"
    skips edge = case edge.arrow of
        Skip _ -> True
        Along _ -> False
        Stay -> False
    taken edge = case edge.arrow of
        Skip optId -> (cfg mode).skip optId /= Never
        Along _ -> True
        Stay -> True
    stateNames = map (stateNameText . (.name)) (Set.toList (places g))
    rule qid = "state rule " <> qid <> " --answer <a> --why <w> --cost <c>"
    triage qid = rule qid <> " | state forward " <> qid
