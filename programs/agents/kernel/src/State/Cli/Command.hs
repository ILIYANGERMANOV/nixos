{- | The @state@ command line (#360's CLI contract): argv parsed into a
'Command' before any effect, the usage text generated from the same tables,
and every failure in the shape the @/self-improve@ analyzer parses:
@state <sub>: what - why@, then @fix: <command>@.
-}
module State.Cli.Command (
    Command (..),
    RunCommand (..),
    InitArgs (..),
    Raise (..),
    Block (..),
    Failure (..),
    Exit (..),
    Usage (..),
    parseCommand,
    parseHook,
    optparseText,
    failureText,
    noteOf,
    explain,
    notStarted,
    help,
) where

import Control.Applicative (many, optional, some, (<**>))
import Data.Bifunctor (first)
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Options.Applicative (ParserInfo)
import Options.Applicative qualified as Opt
import Options.Applicative.Help.Pretty (pretty, vsep)
import State.Category.Flow (loopName)
import State.Category.Graph (Arrow (..), Edge (..), Node (..), OpenGraph (..), Place (..), places)
import State.Category.Mode (Cfg (..), Mode, SkipWhen (Never), cfg, parseByName, qualityName, sizeName)
import State.Category.Step (eventText, stateNameText)
import State.Protocol.Hook (HookName, hookName, hookPurpose)
import State.Protocol.Record (Args (..), Arity (..), Flag (..), Recordable (..), Recording (..), choices, recordCommand, recordables, usageOf)
import State.Run.Ask (Above (..), Basis (..), Kind, OneLine, Parent (..), Proposal (..), QId, kindName, parseKind, parseOneLine, parseQId, qidText)
import State.Run.Ask qualified as Ask
import State.Run.Codec (areaText, logName, reasonText)
import State.Run.Codec qualified as Codec
import State.Run.Event (AgentRole (..), Asker (..), FlowName (..), Note (..), RunId, StateName (..), Stop (..), TaskId (..), childRoles, parseRunId, roleText, runIdText)
import State.Run.Fan qualified as Fan
import State.Run.Fold (Refusal (..), roundOnly)
import State.Run.Id (parseEventId)
import State.Show (tshow)
import State.Table (Steps, agentRoles)
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
      Brief AgentRole (Maybe TaskId)
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

data InitArgs = InitArgs {notes :: FilePath, flow :: FlowName, parent :: Maybe Parent}

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

{- | Help asked for, or argv the grammar rejects: optparse's verdict. Its
exit code tells the two apart, so the shell, which owns exit codes, renders it.
-}
newtype Usage = Usage (Opt.ParserFailure Opt.ParserHelp)

{- | The subcommand, for the failure line, and the command or why it is not
one; else optparse's help or usage error. No command at all is help.
-}
parseCommand :: Steps -> [Text] -> Either Usage (Text, Either Failure Command)
parseCommand steps = \case
    [] -> Right ("help", Right Help)
    -- The grammar has no option before the subcommand but --help: a parsed argv starts with it.
    argv@(sub : _) -> (sub,) <$> runCli (commandInfo steps) argv

-- | @state-hook <name>@'s argv.
parseHook :: [Text] -> Either Usage HookName
parseHook = runCli hookInfo

-- | The full usage: every command, then the run's kinds, stop reasons, roles and areas.
help :: Steps -> Text
help steps = optparseText (fst (Opt.renderFailure (Opt.parserFailure cliPrefs (commandInfo steps) (Opt.ShowHelpText Nothing) []) "state"))

{- | optparse's own parse: a misuse prints its error, then the help of the
command it reached, so @state record nope@ lists every event. The completion
it answers is refused: this CLI offers none, and only a shell asks for it.
-}
runCli :: ParserInfo a -> [Text] -> Either Usage a
runCli pinfo argv = case Opt.execParserPure cliPrefs pinfo (map Text.unpack argv) of
    Opt.Success parsed -> Right parsed
    Opt.Failure failure -> Left (Usage failure)
    Opt.CompletionInvoked _ -> Left (Usage (Opt.parserFailure cliPrefs pinfo (Opt.ErrorMsg "shell completion is not offered") []))

cliPrefs :: Opt.ParserPrefs
cliPrefs = Opt.prefs Opt.showHelpOnError

-- | optparse's text, less the trailing spaces it leaves where it wraps a usage line.
optparseText :: String -> Text
optparseText = Text.unlines . map Text.stripEnd . Text.lines . Text.pack

hookInfo :: ParserInfo HookName
hookInfo = Opt.info (Opt.hsubparser (foldMap hookCommand [minBound .. maxBound]) <**> Opt.helper) (Opt.progDesc "One hook event on stdin, its reply on stdout.")
  where
    hookCommand name = Opt.command (Text.unpack (hookName name)) (Opt.info (pure name) (Opt.progDesc (Text.unpack (hookPurpose name))))

commandInfo :: Steps -> ParserInfo (Either Failure Command)
commandInfo steps =
    Opt.info
        (Opt.hsubparser commands <**> Opt.helper)
        (Opt.header "state - the run of an agent flow, kept in the worktree's log" <> Opt.footerDoc (Just (vsep (map pretty footer))))
  where
    commands =
        mconcat
            [ sub "init" "Start a run, a child run when it names its parent" initArgs
            , Opt.command "record" (Opt.info recordEvent (Opt.progDesc "Record an event: 'state record --help' lists them" <> Opt.footer "A commit event records HEAD."))
            , sub "handback" "Record a role's hand-back, read from stdin" $
                (\role child -> HandbackOf <$> knownRole anyRole role <*> traverse runId child)
                    <$> textArgument "<role>"
                    <*> optional (textOption "child" "<run>" "the child run handing back, when the hand-back names none")
            , sub "next" "Print the next action, its facts and the step's task" (pure (Right Next))
            , sub "brief" "Print a role's brief, a child engineer's task too" $
                (\role task -> OnRun <$> (Brief <$> knownRole anyRole role <*> pure (TaskId <$> task)))
                    <$> textArgument "<role>"
                    <*> optional (textOption "task" "<id>" "the task of the breakdown")
            , sub "show" "Print where the run is and what it holds" (pure (Right (OnRun ShowRun)))
            , freeText "override" "Move the run to a state by hand, saying why" $
                (\target why -> Right (OnRun (Override (StateName target) why)))
                    <$> textArgument "<state>"
                    <*> sentence "<why>"
            , sub "render" "Print a block of the flow, as the skills paste it" $
                (\block flow -> Render <$> maybe (Right States) (named "block" (parseByName blockName)) block <*> flowOf flow)
                    <$> optional (textArgument (choices blockName))
                    <*> optional flowOption
            , freeText "ask" "Ask a question: the run's, a worker's or a child's" $
                (\kind from question -> OnRun <$> (AskQuestion <$> named "kind" parseKind kind <*> maybe (Right Itself) (asker (agentRoles steps)) from <*> oneLine question))
                    <$> textOption "kind" (choices kindName) "the question's kind"
                    <*> optional (textOption "from" "<role|run>" "the worker or child run that asked it")
                    <*> sentence "<question>"
            , sub "rule" "Rule on a question: the answer, why and its cost" $
                (\qid answer why cost basis raise -> OnRun <$> (RuleOn <$> qidOf qid <*> raising raise <*> (Proposal <$> oneLine answer <*> oneLine why <*> oneLine cost <*> traverse basisOf basis)))
                    <$> textArgument "<qid>"
                    <*> textOption "answer" "<a>" "the answer"
                    <*> textOption "why" "<w>" "why it is the answer"
                    <*> textOption "cost" "<c>" "what the answer costs"
                    <*> optional (textOption "basis" "<event-id>|obvious:<why>" "the event that answered it, or why it is obvious")
                    <*> optional raiseOption
            , sub "forward" "Forward a question up, to the parent run or the user" $
                (\qid raise -> OnRun <$> (Forward <$> qidOf qid <*> raising raise)) <$> textArgument "<qid>" <*> optional raiseOption
            , freeText "answer" "Record the answer to a forwarded question" $
                (\qid answer by -> OnRun <$> (Answer <$> qidOf qid <*> pure answer <*> traverse above by))
                    <$> textArgument "<qid>"
                    <*> sentence "<answer>"
                    <*> optional (textOption "by" "user|<run>" "who answered, when not whoever started the run")
            , freeText "stop" "Stop the run, with a reason and why" $
                (\reason why -> (\r -> OnRun (StopRun (Stop r why))) <$> named "stop reason" (parseByName reasonText) reason)
                    <$> textArgument (choices reasonText)
                    <*> sentence "<why>"
            , sub "pending" "List the questions awaiting an answer" (pure (Right (OnRun Pending)))
            , sub "help" "Print this help" (pure (Right Help))
            ]
    footer =
        [ "kinds: " <> choices kindName
        , "stop reasons: " <> choices reasonText
        , "roles: " <> Text.unwords (map roleText (agentRoles steps))
        , "areas (--touches): " <> choices areaText
        , ""
        , "Exit 0 ok; 2 bad usage, a bad log line or a refused event; 1 a git or disk failure."
        , "A refusal prints `state <command>: what - why`, then `fix: <command>`."
        , "Run 'state <command> --help' for a command's arguments."
        ]
    anyRole = agentRoles steps <> childRoles
    sub name about parser = Opt.command name (Opt.info parser (Opt.progDesc about))
    -- Its last words are free text, which may start with a dash: an option it does not take is a word.
    freeText name about parser = Opt.command name (Opt.info parser (Opt.progDesc about <> Opt.forwardOptions))
    raiseOption = textOption "raise" "security" "raise the question to a Security one first"
    raising = \case
        Nothing -> Right AsAsked
        Just "security" -> Right ToSecurity
        Just other -> Left (usage ("--raise " <> other) "a question is only raised to security")
    basisOf raw = case Text.stripPrefix "obvious:" raw of
        Just why -> Obvious <$> oneLine (Text.strip why)
        Nothing -> maybe (Left (usage ("--basis " <> raw) "an event id such as r7f2:12, or obvious:<why>")) (Right . AnsweredBy) (parseEventId raw)
    above = \case
        "user" -> Right TheUser
        raw -> ParentRun <$> runId raw

initArgs :: Opt.Parser (Either Failure Command)
initArgs =
    init'
        <$> textOption "notes" "<dir>" "the directory of the run's notes"
        <*> optional flowOption
        <*> optional (textOption "parent" "<run>" "a child run's parent run")
        <*> optional (textOption "parent-log" "<path>" "the parent's events.jsonl, an absolute path")
        <*> optional (textOption "task" "<id>" "the parent's task this child run takes")
  where
    init' notes flowRaw parentRaw logRaw taskRaw = do
        flow <- flowOf flowRaw
        parent <- case (parentRaw, logRaw, taskRaw) of
            (Nothing, Nothing, Nothing) -> Right Nothing
            (Just run, Just logPath, Just task) -> (\r l -> Just (Parent r l (TaskId task))) <$> runId run <*> parentLog logPath
            _ -> Left (usage "--parent, --parent-log and --task go together" "a child run names its parent's run and log, and its task")
        Right (Init InitArgs {notes = Text.unpack notes, flow, parent})

-- | One subcommand per event the table holds, its flags its options.
recordEvent :: Opt.Parser (Either Failure Command)
recordEvent = Opt.hsubparser (Opt.metavar "EVENT" <> foldMap event recordables)
  where
    event r = Opt.command (Text.unpack r.name) (Opt.info (recording r <$> positionals r <*> flags r) (Opt.progDesc (Text.unpack (describe r)) <> freeWords r))
    recording r positional options = OnRun . Record <$> first (refused r) (r.parse (Args positional options))
    refused r why = Failure BadInput ("record " <> r.name) why (Text.strip ("state record " <> r.name <> " " <> usageOf r))
    positionals r
        | Text.null r.positional = pure []
        | otherwise = many (textArgument r.positional)
    flags r = concat <$> traverse flag r.flags
    flag f = map (f.name,) <$> arity f.arity (Opt.strOption (Opt.long (Text.unpack f.name) <> Opt.metavar (Text.unpack f.value)))
    arity = \case
        Required -> fmap pure
        Optional -> fmap toList . optional
        Repeated -> many
    -- An event's positionals may be free text, which may start with a dash.
    freeWords r = if Text.null r.positional then mempty else Opt.forwardOptions
    describe r = if Text.null (usageOf r) then "no arguments" else usageOf r

flowOption :: Opt.Parser Text
flowOption = textOption "flow" (choices Codec.flowText) "the flow (default engineer)"

flowOf :: Maybe Text -> Either Failure FlowName
flowOf = maybe (Right EngineerFlow) (named "flow" (parseByName Codec.flowText))

textOption :: String -> Text -> String -> Opt.Parser Text
textOption name value about = Opt.strOption (Opt.long name <> Opt.metavar (Text.unpack value) <> Opt.help about)

textArgument :: Text -> Opt.Parser Text
textArgument value = Opt.strArgument (Opt.metavar (Text.unpack value))

-- | One or more words, joined: a shell user need not quote a sentence.
sentence :: Text -> Opt.Parser Text
sentence value = Text.unwords <$> some (textArgument value)

-- | The usage failure, with @state help@ as the fix.
usage :: Text -> Text -> Failure
usage what why = Failure BadInput what why "state help"

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
        Fan.AtWork task -> refused ("an agent for task " <> Codec.taskIdText task) "one works on it already, until its child hands back" "state next"
        Fan.StopUntriaged child -> refused ("a retry of child " <> runIdText child) "its stop is not triaged yet" ("state ask --kind <kind> --from " <> runIdText child <> " <question>")
        Fan.AwaitsUser child -> refused ("a retry of child " <> runIdText child) "its question is open: the retry waits for the answer" "state next"
        Fan.HeavyBusy task heavy -> refused ("an agent for task " <> Codec.taskIdText task) ("it is heavy and heavy task " <> Codec.taskIdText heavy <> " is at work: one heavy task at a time") "state next"
        Fan.Unmerged tasks -> refused "the run's end" ("tasks neither merged nor parked: " <> Text.unwords (map Codec.taskIdText (toList tasks))) "state next"
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
