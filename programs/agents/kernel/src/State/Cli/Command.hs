{- | The @state@ command line (#360's CLI contract): argv parsed into a
'Command' before any effect, the usage text generated from the same tables,
and every failure in the shape the @/self-improve@ analyzer parses:
@state <sub>: what - why@, then @fix: <command>@.
-}
module State.Cli.Command (
    Command (..),
    Until (seq),
    RunCommand (..),
    Location (..),
    locationOf,
    BriefPart (..),
    InitArgs (..),
    Origin (..),
    defaultFlow,
    Raise (..),
    Block (..),
    Failure (..),
    Exit (..),
    Usage (..),
    parseCommand,
    parseHook,
    optparseText,
    failureText,
    initFix,
    tenXInitFix,
    architectInitFix,
    chiefInitFix,
    CommandRefusal (..),
    refusedNote,
    explainRefusal,
    refusalCode,
    explain,
    unknownEvent,
    anyEvent,
    openQid,
    notOpenYet,
    retryOf,
    answeredQid,
    notStarted,
    help,
) where

import Control.Applicative (many, optional, some, (<**>), (<|>))
import Data.Bifunctor (first)
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Version (showVersion)
import Numeric.Natural (Natural)
import Options.Applicative (ParserInfo)
import Options.Applicative qualified as Optparse
import Options.Applicative.Help.Pretty (pretty, vsep)
import Paths_state (version)
import State.Artifact (
    AbsPath,
    FileKind,
    Uri,
    UrlKind,
    absPathText,
    fileKindText,
    parseUri,
    uriRule,
    uriText,
    urlKindText,
 )
import State.Category.Flow (ScopePath, qualifyText, unqualify)
import State.Category.Fuel (Fuel, choices, parseByName)
import State.Category.Graph (
    Cap (..),
    Node (..),
    OpenGraph (..),
    Place (..),
    placeName,
    places,
 )
import State.Category.Meter (someMeterName)
import State.Category.Step (
    EventName (..),
    eventText,
    handedBackOutcome,
    stateNameText,
 )
import State.Protocol.Hook (HookName, hookName, hookPurpose)
import State.Protocol.Record (
    Args (..),
    Arity (..),
    Flag (..),
    Option (..),
    Recordable (..),
    Recording (..),
    capRecords,
    extend,
    extendOption,
    recordCommand,
    recordables,
    spawnChildOption,
    usageOf,
 )
import State.Role (RoleDef (..), defaultFlow, fuelTakes)
import State.Role qualified as Role
import State.Run.Ask (
    Above (..),
    Basis (..),
    ChildTask (..),
    Kind,
    Link (..),
    OneLine,
    Parent (..),
    Proposal (..),
    QId,
    Question (..),
    Reply (..),
    Route (..),
    kindName,
    parseOneLine,
    parseQId,
    qidText,
    replyWords,
 )
import State.Run.Ask qualified as Ask
import State.Run.Codec (areaText, handoverReasonText, reasonText)
import State.Run.Codec qualified as Codec
import State.Run.Epic (EpicMove (..))
import State.Run.Epic qualified as Epic
import State.Run.Event (
    AgentRole (..),
    Asker (..),
    Asking (..),
    Child (..),
    FlowName (..),
    Handover (..),
    Note (..),
    RefusalCode (..),
    RunId,
    SpanId (..),
    StateName (..),
    Stop (..),
    Task,
    TaskId (..),
    TaskNo,
    TaskState (Kept),
    parseRunId,
    parseTaskNo,
    roleText,
    runIdText,
    taskNoText,
 )
import State.Run.Fan qualified as Fan
import State.Run.Fold (Answer (about, given), Refusal (..), RunState (..))
import State.Run.Fold qualified as Fold
import State.Run.Gap (GapMove)
import State.Run.Gap qualified as Gap
import State.Run.Id (EventRef, eventRefText, parseEventId, parseEventRef)
import State.Show (tshow)
import State.Step.Artifact (
    Branch (..),
    EpicName,
    Shape (..),
    ShellPath,
    epicNameText,
    parseEpicName,
    parsePrUrl,
    parseRepo,
    prUrlRule,
    shellPath,
    shellPathRule,
 )
import State.Step.Catalog (shownEdges)
import State.Table (Steps, agentRoles)
import System.FilePath (dropTrailingPathSeparator, normalise)
import Text.Read (readMaybe)

data Command
    = Init InitArgs
    | -- | The hand-back on stdin, from this role, of this child run when it names none.
      HandbackOf AgentRole (Maybe RunId)
    | Next
    | Render Block FlowName
    | Help
    | -- | The worktree's run moves to the worktree at this directory; its notes stay.
      Move FilePath
    | -- | A run's events as stored, one envelope per line, in seq order.
      Dump RunId
    | {- | The chief's request in focus waits, saying where it stands when it
      recorded work; this waiting request takes the focus, else a new one.
      -}
      Focus (Maybe TaskNo) (Maybe OneLine)
    | -- | A card per request of the chief's run, and per child run.
      Tasks
    | -- | The worktree's run hands over to a fresh agent, its changed files registered again first.
      HandOver Handover
    | -- | The artifact a run logged at this seq: its bytes, its URL, or why neither.
      ShowArtifact EventRef
    | {- | A file or URL the worktree's run registers, derived from its
      artifact of this seq, and made by the agent of this span, if any.
      -}
      Register (Location FilePath) (Maybe Natural) (Maybe SpanId)
    | {- | The packet a fresh agent resumes from: of the run named, else the
      session's or the worktree's, as it was after this line, if one is given.
      -}
      Resume (Maybe RunId) (Maybe Until)
    | {- | The gap logged at this line moves on, in its own run: a fix
      proposed, fixed, or not to be fixed.
      -}
      MoveGap EventRef GapMove
    | OnRun RunCommand

{- | The packet as it was after the line of this seq (@--until@): a seq
counts from 1, as the log's first line is its @started@.
-}
newtype Until = Until {seq :: Natural}
    deriving stock (Eq, Show)

-- | A command on the worktree's run, read and written under the log's lock.
data RunCommand
    = Record Recording
    | -- | An event the grammar lacks, refused with the events the run takes where it is.
      RecordUnknown Text
    | Brief AgentRole BriefPart
    | ShowRun
    | Override StateName Text
    | -- | The line of this seq is void, and why.
      Void Natural Text
    | -- | The run's own question, sent as its row says or to the user at once.
      AskOwn Kind Route OneLine
    | -- | A question a worker or a child run put to the run.
      AskFrom Kind Asker OneLine
    | -- | A question's id as typed, checked against the run's open ones ('openQid').
      RuleOn Text Raise Proposal
    | Forward Text Raise
    | -- | A stopped child's task taken again: its stop triaged as Stuck and ruled a retry, and why.
      Retry TaskId OneLine
    | -- | The answer that came down; by the run's principal unless named.
      Answer Text Reply (Maybe Above)
    | -- | A pending question left open for a later answer, and why.
      Park Text OneLine
    | StopRun Stop
    | Pending
    | -- | A note under its topic, then its text.
      NoteOn Text Text
    | -- | An epic of the run opened, made ready for review or merged.
      MoveEpic EpicName EpicMove

{- | Where an artifact is, with a kind that fits it: a URL, or a file at a
path, as typed until the shell reads it.
-}
data Location path = AtUrl UrlKind Uri | AtPath FileKind path
    deriving stock (Eq, Show, Functor, Foldable, Traversable)

-- | What of a role's brief to print: all of it, with a child engineer's task, or one step's section.
data BriefPart = Whole (Maybe TaskId) | Section StateName
    deriving stock (Eq, Show)

{- | A child's flow, when not named, is its parent's fan-out's; a top run's
is 'defaultFlow'.
-}
data InitArgs = InitArgs
    { notes :: ShellPath
    , flow :: Maybe FlowName
    , origin :: Origin
    , goal :: Maybe Text
    -- ^ The run's goal, word for word; a resumed run keeps the one it started with.
    }

{- | Who starts the run: the user, on a PR of its own or a round on the one
@--pr@ names; a parent run, whose task gives the shape; or, with @--child@,
the agent that spawned this subagent with no run of its own to link, on a PR
of its own or a round as the user's.
-}
data Origin = FromUser Shape | FromParent Parent | FromCaller Shape
    deriving stock (Eq, Show)

-- | A question kept at its kind, or raised to 'Ask.Security' first.
data Raise = AsAsked | ToSecurity
    deriving stock (Eq, Show)

-- | What @state answer@'s words are: an option chosen, a reply none covers, or why it is parked.
data AnswerMode = AsChosen | AsOther | AsPark

-- | What @state render@ prints: each a block the skills paste.
data Block = States | FuelRows | Mermaid | Kinds | StopRule | PlanWrong | InitLine
    deriving stock (Eq, Show, Enum, Bounded)

{- | Why a command did nothing, as @state <sub>: what - why@ and a @fix:@
line naming the command to run instead.
-}
data Failure = Failure {exit :: Exit, what :: Text, why :: Text, fix :: Text}
    deriving stock (Eq, Show)

{- | Exit 2 for bad usage, a bad log line or a refused event; exit 1 for git
or disk; for @state artifact show@, exit 3 for an artifact whose bytes were
not stored and exit 4 for a line that is no artifact (#552's Appendix B E).
-}
data Exit = BadInput | Outage | NotStored | NotAnArtifact
    deriving stock (Eq, Show)

failureText :: Text -> Failure -> Text
failureText sub failure =
    "state "
        <> sub
        <> ": "
        <> failure.what
        <> " - "
        <> failure.why
        <> "\nfix: "
        <> failure.fix
        <> "\n"

-- | The fix where a run is missing: start one, its notes dir as the skills name it.
initFix :: Text
initFix = "state init --notes /tmp/engineer-<owner>-<repo>-<slug>/"

-- | The 10x lead's @state init@ line, run in the run directory its skill names.
tenXInitFix :: Text
tenXInitFix = "state init --notes \"$PWD\" --flow 10x"

-- | The architect's @state init@ line: its notes hold the research, its ticket the design.
architectInitFix :: Text
architectInitFix = "state init --notes /tmp/architect-<owner>-<repo>-<slug>/ --flow architect"

-- | The chief's @state init@ line: one run holds every request of the session.
chiefInitFix :: Text
chiefInitFix = "state init --notes /tmp/chief-<owner>-<repo>-<slug>/ --flow chief"

{- | Help asked for, or argv the grammar rejects: optparse's verdict. Its
exit code tells the two apart, so the shell, which owns exit codes, renders it.
-}
newtype Usage = Usage (Optparse.ParserFailure Optparse.ParserHelp)

{- | The subcommand, for the failure line, and the command or why it is not
one; else optparse's help or usage error. No command at all is help.
-}
parseCommand :: Steps -> [Text] -> Either Usage (Text, Either Failure Command)
parseCommand steps = \case
    [] -> Right ("help", Right Help)
    -- A scoped event is its step's event inside a scope: the scope goes in its Args.
    "record" : event : rest
        -- An event the table lacks is refused by the run, which knows the events it takes where it is.
        | (_, local) <- unqualify event
        , not (Text.isPrefixOf "-" local)
        , local `notElem` map (.name) recordables ->
            Right ("record", Right (OnRun (RecordUnknown event)))
        | (scope, local) <- unqualify event ->
            ("record",) <$> runCli (commandInfo steps scope) ("record" : local : rest)
    -- The grammar has no option before the subcommand but --help: a parsed argv starts with it.
    argv@(sub : _) -> (sub,) <$> runCli (commandInfo steps mempty) argv

-- | @state-hook <name>@'s argv.
parseHook :: [Text] -> Either Usage HookName
parseHook = runCli hookInfo

-- | The full usage: every command, then the run's kinds, stop reasons, roles and areas.
help :: Steps -> Text
help steps =
    optparseText
        ( fst
            ( Optparse.renderFailure
                ( Optparse.parserFailure
                    cliPrefs
                    (commandInfo steps mempty)
                    (Optparse.ShowHelpText Nothing)
                    []
                )
                "state"
            )
        )

{- | optparse's own parse: a misuse prints its error, then the help of the
command it reached, so @state record nope@ lists every event. The completion
it answers is refused: this CLI offers none, and only a shell asks for it.
-}
runCli :: ParserInfo a -> [Text] -> Either Usage a
runCli pinfo argv = case Optparse.execParserPure cliPrefs pinfo (map Text.unpack argv) of
    Optparse.Success parsed -> Right parsed
    Optparse.Failure failure -> Left (Usage failure)
    Optparse.CompletionInvoked _ ->
        Left
            ( Usage
                ( Optparse.parserFailure
                    cliPrefs
                    pinfo
                    (Optparse.ErrorMsg "shell completion is not offered")
                    []
                )
            )

{- | No backtracking: a surplus argument fails in the subcommand it follows,
so its help, not the top-level one, follows the error.
-}
cliPrefs :: Optparse.ParserPrefs
cliPrefs = Optparse.prefs (Optparse.showHelpOnError <> Optparse.noBacktrack)

-- | optparse's text, less the trailing spaces it leaves where it wraps a usage line.
optparseText :: String -> Text
optparseText = Text.unlines . map Text.stripEnd . Text.lines . Text.pack

hookInfo :: ParserInfo HookName
hookInfo =
    Optparse.info
        ( Optparse.hsubparser (foldMap hookCommand [minBound .. maxBound])
            <**> Optparse.helper
        )
        (Optparse.progDesc "One hook event on stdin, its reply on stdout.")
  where
    hookCommand name =
        Optparse.command
            (Text.unpack (hookName name))
            (Optparse.info (pure name) (Optparse.progDesc (Text.unpack (hookPurpose name))))

-- | The grammar, its @record@ events inside the scope their name gave.
commandInfo :: Steps -> ScopePath -> ParserInfo (Either Failure Command)
commandInfo steps scope =
    Optparse.info
        ( Optparse.hsubparser commands
            <**> Optparse.helper
            <**> Optparse.simpleVersioner (showVersion version)
        )
        ( Optparse.header "state - the run of an agent flow, kept in its run store"
            <> Optparse.footerDoc (Just (vsep (map pretty footer)))
        )
  where
    commands =
        mconcat
            [ sub "init" "Start a run: a child of --parent, a round on --pr" initArgs
            , Optparse.command
                "record"
                ( Optparse.info
                    (recordEvent scope)
                    ( Optparse.progDesc "Record an event: 'state record --help' lists them"
                        <> Optparse.footer "A commit event records HEAD."
                    )
                )
            , sub "handback" "Record a role's hand-back, read from stdin" $
                (\role child -> HandbackOf <$> knownRole anyRole role <*> traverse runId child)
                    <$> textArgument "<role>"
                    <*> optional
                        ( textOption
                            "child"
                            "<run>"
                            "the child run handing back, when the hand-back names none"
                        )
            , sub
                "next"
                "Print the next action, its facts and the step's task"
                (pure (Right Next))
            , sub "brief" "Print a role's brief, one section, or a child's task" $
                (\role part -> OnRun <$> (Brief <$> knownRole anyRole role <*> pure part))
                    <$> textArgument "<role>"
                    <*> ( Section . StateName
                            <$> textOption "section" "<step>" "only the section of this step"
                            <|> Whole . fmap TaskId
                                <$> optional (textOption "task" "<id>" "the task of the breakdown")
                        )
            , sub
                "show"
                "Print where the run is and what it holds"
                (pure (Right (OnRun ShowRun)))
            , freeText "override" "Move the run to a state by hand, saying why" $
                (\target why -> Right (OnRun (Override (StateName target) why)))
                    <$> textArgument "<state>"
                    <*> sentence "<why>"
            , freeText "void" "Void a line logged in error, by its seq, saying why" $
                (\n why -> OnRun . (`Void` why) <$> seqOf n)
                    <$> textArgument "<seq>"
                    <*> sentence "<why>"
            , sub
                "move"
                "Move the run to another worktree; its notes stay"
                (Right . Move . Text.unpack <$> textArgument "<worktree>")
            , sub
                "dump"
                "Print a run's events, one JSON envelope per line"
                (fmap Dump . runId <$> textArgument "<run>")
            , sub "render" "Print a block of the flow, as the skills paste it" $
                ( \block flow ->
                    Render
                        <$> maybe (Right States) (named "block" (parseByName blockName)) block
                        <*> flowOf flow
                )
                    <$> optional (textArgument (choices blockName))
                    <*> optional flowOption
            , freeText "ask" "Ask a question: the run's, a worker's or a child's" $
                askOf
                    <$> textOption "kind" (choices kindName) "the question's kind"
                    <*> optional
                        (textOption "from" "<role|run>" "the worker or child run that asked it")
                    <*> optional
                        ( textOption
                            "to"
                            "user"
                            "the run's own question, sent up at once: asked of the user, or handed back by a child"
                        )
                    <*> sentence "<question>"
            , sub "rule" "Rule on a question: the answer, why and its cost" $
                ( \qid strays answer why cost basis raise ->
                    OnRun
                        <$> ( RuleOn
                                <$> oneWordEach qid strays
                                <*> raising raise
                                <*> ( Proposal
                                        <$> oneLine answer
                                        <*> oneLine why
                                        <*> oneLine cost
                                        <*> traverse basisOf basis
                                    )
                            )
                )
                    <$> textArgument "<qid>"
                    -- The words past an option's one: an unquoted answer, why or cost, refused below.
                    <*> many (Optparse.strArgument @Text (Optparse.metavar "" <> Optparse.internal))
                    <*> textOption "answer" "<a>" "the answer"
                    <*> textOption "why" "<w>" "why it is the answer"
                    <*> textOption "cost" "<c>" "what the answer costs"
                    <*> optional
                        ( textOption
                            "basis"
                            "<event-id>|obvious:<why>"
                            "the event that answered it, or why it is obvious"
                        )
                    <*> optional raiseOption
            , sub "retry" "Retry a stopped child's task, printing its brief" $
                (\task why -> OnRun . Retry (TaskId task) <$> oneLine why)
                    <$> textArgument "<task>"
                    <*> textOption "why" "<w>" "why another try may succeed"
            , sub "forward" "Forward a question up, to the parent run or the user" $
                (\qid raise -> OnRun . Forward qid <$> raising raise)
                    <$> textArgument "<qid>"
                    <*> optional raiseOption
            , freeText "answer" "Record the answer to a question, or park it" $
                answerOf
                    <$> textArgument "<qid>"
                    <*> ( Optparse.flag'
                            AsOther
                            ( Optparse.long "other"
                                <> Optparse.help "a reply none of the options covers, or a new request"
                            )
                            <|> Optparse.flag'
                                AsPark
                                ( Optparse.long "park"
                                    <> Optparse.help "leave the question open for a later answer: the words say why"
                                )
                            <|> pure AsChosen
                        )
                    <*> sentence "<answer>"
                    <*> optional
                        (textOption "by" "user|<run>" "who answered, when not whoever started the run")
            , freeText "stop" "Stop the run, with a reason and why" $
                ( \reason why ->
                    (\r -> OnRun (StopRun (Stop r why)))
                        <$> named "stop reason" (parseByName reasonText) reason
                )
                    <$> textArgument (choices reasonText)
                    <*> sentence "<why>"
            , sub
                "pending"
                "List the questions awaiting an answer"
                (pure (Right (OnRun Pending)))
            , sub "focus" "Turn to a waiting request, else a new one" $
                ( \task summary ->
                    Focus
                        <$> traverse (named "request" parseTaskNo) task
                        <*> traverse oneLine summary
                )
                    <$> optional (textArgument "<request>")
                    <*> optional
                        ( textOption
                            "summary"
                            "<line>"
                            "where the request in focus stands, once it recorded work"
                        )
            , sub "tasks" "Print each request's card and resume advice" (pure (Right Tasks))
            , Optparse.command
                "artifact"
                ( Optparse.info
                    (artifactShow <|> artifactRegister)
                    ( Optparse.progDesc
                        "Register a file or URL; 'artifact show' prints one"
                    )
                )
            , freeText "note" "Note context for a fresh agent, under a topic" $
                (\topic text -> Right (OnRun (NoteOn topic text)))
                    <$> textOption "topic" "<t>" "what the note is about"
                    <*> sentence "<text>"
            , Optparse.command
                "epic"
                ( Optparse.info
                    (Optparse.hsubparser (epicOpen <> epicReady <> epicMerged))
                    (Optparse.progDesc "Open an epic, mark it ready for review, or merged")
                )
            , sub "handover" "Hand the run over to a fresh agent" $
                ( \reason summary first' rest ->
                    (\r -> HandOver (Handover r summary (first' :| rest)))
                        <$> named "handover reason" (parseByName handoverReasonText) reason
                )
                    <$> textOption "reason" (choices handoverReasonText) "why the agent hands over"
                    <*> textOption "summary" "<s>" "where the work stands"
                    <*> nextStep mempty
                    <*> many (nextStep Optparse.hidden)
            , sub "resume" "Print the packet a fresh agent resumes the run from" $
                (\run k -> Resume <$> traverse runId run <*> traverse untilOf k)
                    <$> optional (textArgument "<run>")
                    <*> optional
                        ( textOption
                            "until"
                            "<seq>"
                            "the packet as it was after the line of this seq"
                        )
            , Optparse.command
                "gap"
                ( Optparse.info
                    ( Optparse.hsubparser
                        ( sub "proposed" "A gap's fix is proposed in a PR" (byPr Gap.Propose)
                            <> sub "fixed" "A gap is fixed by a PR" (byPr (Gap.Close . Gap.Fixed))
                            <> freeText
                                "wontfix"
                                "A gap is left as it is, saying why"
                                ( (\raw why -> MoveGap <$> gapAt raw <*> (Gap.Close . Gap.WontFix <$> oneLine why))
                                    <$> textArgument "<run:seq>"
                                    <*> sentence "<reason>"
                                )
                        )
                    )
                    (Optparse.progDesc "Move a gap on: a fix proposed, fixed, or won't fix")
                )
            , sub "help" "Print this help" (pure (Right Help))
            ]
    byPr move =
        (\raw pr -> MoveGap <$> gapAt raw <*> (move <$> prUri pr))
            <$> textArgument "<run:seq>"
            <*> textOption "pr" "<url>" "the PR"
    gapAt raw =
        maybe
            ( Left
                (usage ("gap " <> raw) "a gap is named <run:seq>, as state resume prints it")
            )
            Right
            (parseEventRef raw)
    prUri raw =
        maybe
            (Left (Failure BadInput ("--pr " <> raw) uriRule "state help"))
            Right
            (parseUri raw)
    artifactShow =
        Optparse.hsubparser
            ( Optparse.command
                "show"
                ( Optparse.info
                    (artifactAt <$> textArgument "<run:seq>")
                    ( Optparse.progDesc
                        "Print an artifact's stored bytes or its URL; exit 3 when its bytes were not stored, 4 when the line is no artifact"
                    )
                )
            )
    artifactAt raw =
        maybe
            ( Left
                ( usage
                    ("artifact " <> raw)
                    "an artifact is named <run:seq>, as state artifact printed it"
                )
            )
            (Right . ShowArtifact)
            (parseEventRef raw)
    artifactRegister =
        ( \raw kind from by ->
            Register
                <$> locationOf raw kind
                <*> traverse seqOf from
                <*> traverse (fmap SpanId . seqOf) by
        )
            <$> textArgument "<path|url>"
            <*> textOption
                "kind"
                "<kind>"
                ( Text.unpack
                    ( "a file's kind, "
                        <> choices fileKindText
                        <> ", or a URL's, "
                        <> choices urlKindText
                    )
                )
            <*> optional
                (textOption "from" "<seq>" "the seq of the artifact of this run it derives from")
            <*> optional
                ( textOption
                    "span"
                    "<seq>"
                    "the seq of the span_started of the agent that made it"
                )
    epicOpen =
        sub "open" "Open an epic: the branch its tasks build on" $
            ( \name repo branch ->
                (\epic r -> OnRun (MoveEpic epic (Opens r (Branch branch))))
                    <$> epicOf name
                    <*> repoOf repo
            )
                <$> textArgument "<name>"
                <*> textOption "repo" "<owner/name>" "the GitHub repo of the epic's branch"
                <*> textOption "branch" "<b>" "the epic's branch"
    epicReady =
        sub "ready" "An epic's final PR is open for review" $
            ( \name pr ->
                (\epic url -> OnRun (MoveEpic epic (Readies url)))
                    <$> epicOf name
                    <*> epicPr pr
            )
                <$> textArgument "<name>"
                <*> textOption "pr" "<url>" "the epic's final PR"
    epicMerged =
        sub "merged" "An epic's final PR merged" $
            fmap (OnRun . (`MoveEpic` Merges)) . epicOf <$> textArgument "<name>"
    epicOf raw =
        maybe
            (Left (usage ("epic " <> raw) "an epic's name is ASCII letters, digits and ._-"))
            Right
            (parseEpicName raw)
    repoOf raw =
        maybe
            (Left (usage ("--repo " <> raw) "a repo is <owner>/<name>, as gh names it"))
            Right
            (parseRepo raw)
    epicPr raw =
        maybe
            (Left (usage ("--pr " <> raw) ("the PR is " <> prUrlRule)))
            Right
            (parsePrUrl raw)
    nextStep hiding =
        Optparse.strOption
            ( Optparse.long "next"
                <> Optparse.metavar "<step>"
                <> Optparse.help "a next step, once per step"
                <> hiding
            )
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
    anyRole = agentRoles steps <> map (.name) Role.roles
    sub name about parser = Optparse.command name (Optparse.info parser (Optparse.progDesc about))
    -- Its last words are free text, which may start with a dash: an option it does not take is a word.
    freeText name about parser =
        Optparse.command
            name
            (Optparse.info parser (Optparse.progDesc about <> Optparse.forwardOptions))
    raiseOption = textOption "raise" "security" "raise the question to a Security one first"
    raising = \case
        Nothing -> Right AsAsked
        Just "security" -> Right ToSecurity
        Just other -> Left (usage ("--raise " <> other) "a question is only raised to security")
    basisOf raw = case Text.stripPrefix "obvious:" raw of
        Just why -> Obvious <$> oneLine (Text.strip why)
        Nothing ->
            maybe
                (Left (usage ("--basis " <> raw) "an event id such as r7f2:12, or obvious:<why>"))
                (Right . AnsweredBy)
                (parseEventId raw)
    above = \case
        "user" -> Right TheUser
        raw -> ParentRun <$> runId raw
    askOf kind from to question = case (from, to) of
        (Nothing, Nothing) -> own ByRow
        (Nothing, Just "user") -> own ToUser
        (Nothing, Just other) -> Left (usage ("--to " <> other) "a question is only sent to the user")
        (Just _, Just _) ->
            Left
                ( usage
                    "--to with --from"
                    "only the run's own question is sent up at once; a worker's or a child's is triaged here"
                )
        (Just raw, Nothing) ->
            OnRun
                <$> (AskFrom <$> kindOf kind <*> asker (agentRoles steps) raw <*> oneLine question)
      where
        own route = OnRun <$> (AskOwn <$> kindOf kind <*> pure route <*> oneLine question)
    answerOf qid mode words' by = case (mode, by) of
        (AsChosen, _) -> OnRun . Answer qid (Chose words') <$> traverse above by
        (AsOther, _) -> OnRun . Answer qid (Other words') <$> traverse above by
        (AsPark, Nothing) -> OnRun . Park qid <$> oneLine words'
        (AsPark, Just _) ->
            Left (usage "--park with --by" "a park is the run's own: it names no one above")
    oneWordEach qid = \case
        [] -> Right qid
        _ : _ ->
            Left
                ( Failure
                    BadInput
                    "--answer, --why and --cost"
                    "each takes one word: quote a longer one"
                    ("state rule " <> qid <> " --answer \"<a>\" --why \"<w>\" --cost \"<c>\"")
                )

{- | An artifact's location and kind, as typed: text that is an absolute URI
is a URL, any other a path. A kind that does not fit the location is
refused, before anything is read or written.
-}
locationOf :: Text -> Text -> Either Failure (Location FilePath)
locationOf raw kind = case (parseUri raw, parseByName fileKindText kind, parseByName urlKindText kind) of
    (Just uri, _, Just urlKind) -> Right (AtUrl urlKind uri)
    (Just _, Just _, Nothing) ->
        Left
            ( Failure
                BadInput
                ("--kind " <> kind)
                ("a URL's kind is " <> choices urlKindText)
                ("state artifact " <> raw <> " --kind <kind>, or ./" <> raw <> " for a file")
            )
    (Nothing, Just fileKind, _) -> Right (AtPath fileKind (Text.unpack raw))
    (Nothing, Nothing, Just _) ->
        Left
            ( Failure
                BadInput
                raw
                ("a " <> kind <> " is a URL: " <> uriRule)
                ("state artifact <url> --kind " <> kind)
            )
    (_, Nothing, Nothing) ->
        Left
            ( usage
                ("no artifact kind " <> kind)
                ( "a file's kind is "
                    <> choices fileKindText
                    <> ", a URL's "
                    <> choices urlKindText
                )
            )

initArgs :: Optparse.Parser (Either Failure Command)
initArgs =
    init'
        <$> textOption "notes" "<dir>" "the directory of the run's notes, an absolute path"
        <*> optional flowOption
        <*> optional (textOption "parent" "<run>" "a child run's parent run")
        <*> optional
            (textOption "task" "<id>" "the task of the parent's fan-out this child run takes")
        <*> optional
            (textOption "pr" "<url>" "the open PR a user's run takes another round on")
        <*> Optparse.switch
            ( Optparse.long "child"
                <> Optparse.help
                    "a subagent's run whose spawner holds no run to link: it hands everything back"
            )
        <*> optional (textOption "goal" "<goal>" "the run's goal, word for word")
  where
    init' notesRaw flowRaw parentRaw taskRaw prRaw child goal = do
        notes <- notesDir notesRaw
        flow <- traverse flowNamed flowRaw
        let mine = if child then FromCaller else FromUser
        origin <- case (prRaw, parentRaw, taskRaw) of
            _ | child, any isJust [parentRaw, taskRaw] -> Left childWithParent
            (Nothing, Nothing, Nothing) -> Right (mine OwnPr)
            (Just pr, Nothing, Nothing) -> mine . RoundOn <$> roundPr pr
            (Just _, _, _) ->
                Left
                    (usage "--pr with --parent" "a child run takes its PR from its parent's task")
            (Nothing, Just run, Just task) -> (\r -> FromParent (Parent r (InFan (Tasked (TaskId task))))) <$> runId run
            (Nothing, Just run, Nothing) -> (\r -> FromParent (Parent r Direct)) <$> runId run
            (Nothing, Nothing, Just _) ->
                Left
                    ( usage
                        "--task without --parent"
                        "a child run names its parent's run, and its task at a fan-out"
                    )
        Right (Init InitArgs {notes, flow, origin, goal})
    childWithParent =
        usage
            "--child with --parent"
            "a --child run links to no parent run; a linked child names --parent alone, and --task at a fan-out"
    roundPr raw =
        maybe
            ( Left
                ( Failure
                    BadInput
                    ("--pr " <> raw)
                    ("the PR is " <> prUrlRule)
                    "state init --notes <dir> --pr https://github.com/<owner>/<repo>/pull/<n>"
                )
            )
            Right
            (parsePrUrl raw)

-- | One subcommand per event the table holds, its flags its options.
recordEvent :: ScopePath -> Optparse.Parser (Either Failure Command)
recordEvent scope = Optparse.hsubparser (Optparse.metavar "EVENT" <> foldMap event recordables)
  where
    event r =
        Optparse.command
            (Text.unpack r.name)
            ( Optparse.info
                (recording r <$> positionals r <*> flags r)
                (Optparse.progDesc (Text.unpack (describe r)) <> freeWords r)
            )
    recording r positional options =
        OnRun . Record <$> first (refused r) (r.parse (Args scope positional options))
    refused r why =
        Failure
            BadInput
            ("record " <> qualified r)
            why
            (Text.strip ("state record " <> qualified r <> " " <> usageOf r))
    qualified r = qualifyText scope r.name
    positionals r
        | Text.null r.positional = pure []
        | otherwise = many (textArgument r.positional)
    flags r = concat <$> traverse flag r.flags
    flag f =
        map (f.name,)
            <$> arity
                f.arity
                ( Optparse.strOption
                    (Optparse.long (Text.unpack f.name) <> Optparse.metavar (Text.unpack f.value))
                )
    arity = \case
        Required -> fmap pure
        Optional -> fmap toList . optional
        Repeated -> many
    -- An event's positionals may be free text, which may start with a dash.
    freeWords r = if Text.null r.positional then mempty else Optparse.forwardOptions
    describe r = if Text.null (usageOf r) then "no arguments" else usageOf r

flowOption :: Optparse.Parser Text
flowOption = textOption "flow" (choices Codec.flowText) "the flow (default engineer)"

flowOf :: Maybe Text -> Either Failure FlowName
flowOf = maybe (Right defaultFlow) flowNamed

flowNamed :: Text -> Either Failure FlowName
flowNamed = named "flow" (parseByName Codec.flowText)

textOption :: String -> Text -> String -> Optparse.Parser Text
textOption name value about =
    Optparse.strOption
        ( Optparse.long name
            <> Optparse.metavar (Text.unpack value)
            <> Optparse.help about
        )

textArgument :: Text -> Optparse.Parser Text
textArgument value = Optparse.strArgument (Optparse.metavar (Text.unpack value))

-- | One or more words, joined: a shell user need not quote a sentence.
sentence :: Text -> Optparse.Parser Text
sentence value = Text.unwords <$> some (textArgument value)

-- | The usage failure, with @state help@ as the fix.
usage :: Text -> Text -> Failure
usage what why = Failure BadInput what why "state help"

oneLine :: Text -> Either Failure OneLine
oneLine raw =
    maybe
        (Left (usage "a line break" "answers, reasons and questions are one line each"))
        Right
        (parseOneLine raw)

named :: Text -> (Text -> Maybe a) -> Text -> Either Failure a
named what parse raw =
    maybe
        ( Left
            (usage ("no " <> what <> " " <> raw) ("see the " <> what <> "s state help lists"))
        )
        Right
        (parse raw)

runId :: Text -> Either Failure RunId
runId = named "run id" parseRunId

-- | A line's seq, as @recorded <seq>@ and the log print it.
seqOf :: Text -> Either Failure Natural
seqOf raw =
    maybe
        (Left (usage ("seq " <> raw) "a seq is a line's number in the log, from 1"))
        Right
        (readMaybe (Text.unpack raw))

-- | An @--until@ seq: a line's, so from 1.
untilOf :: Text -> Either Failure Until
untilOf raw =
    seqOf raw >>= \case
        0 ->
            Left (usage ("--until " <> raw) "a seq is a line's number in the log, from 1")
        n -> Right (Until n)

-- | A kind in any case: the hand-back's @NEEDS_DECISION <Kind>@ alone is spelled exactly.
kindOf :: Text -> Either Failure Kind
kindOf raw =
    maybe
        (Left (usage ("no kind " <> raw) ("one of " <> choices kindName)))
        Right
        (parseByName (Text.toLower . kindName) (Text.toLower raw))

knownRole :: [AgentRole] -> Text -> Either Failure AgentRole
knownRole roles raw
    | AgentRole raw `elem` roles = Right (AgentRole raw)
    | otherwise =
        Left
            (usage ("no role " <> raw) ("one of " <> Text.unwords (map roleText roles)))

{- | A role a step runs as, else a child run by its id: a run id never names a
role, which the step table spells in full.
-}
asker :: [AgentRole] -> Text -> Either Failure Asker
asker roles raw
    | AgentRole raw `elem` roles = Right (Subagent (AgentRole raw))
    | otherwise = ChildRun <$> runId raw

{- | A run's notes dir, one spelling of it: the pointer, the log's start, the
same-dir check and init's @run@ line all hold this value. Unquoted, as the
@run@ line and the brief's init line print it, and a later reader runs in
another directory than init did.
-}
notesDir :: Text -> Either Failure ShellPath
notesDir raw =
    maybe
        ( Left
            (usage ("--notes " <> raw) ("the notes dir is " <> Text.pack shellPathRule))
        )
        Right
        (shellPath (dropTrailingPathSeparator (normalise (Text.unpack raw))))

blockName :: Block -> Text
blockName = \case
    States -> "states"
    FuelRows -> "fuel"
    Mermaid -> "mermaid"
    Kinds -> "kinds"
    StopRule -> "stop-rule"
    PlanWrong -> "plan-wrong"
    InitLine -> "init"

-- | A log whose first line starts no run: it has no flow to explain against.
notStarted :: Failure
notStarted =
    Failure
        BadInput
        "the log"
        "its first line is not started"
        "state init --notes <dir>"

{- | A refusal a command logs as @refused@: the fold's, or one the command
meets before it folds. A parse or usage failure is none: it logs nothing
and has no code.
-}
data CommandRefusal
    = FoldRefused Refusal
    | -- | A file the command reads is missing, or may not be read.
      FileUnreadable AbsPath
    | -- | Evidence naming a line no run stores: the run, and the seq.
      UnknownEvent EventRef
    deriving stock (Eq, Show)

-- | A refusal as the log keeps it, for @next@ and @show@ to warn of.
refusedNote :: OpenGraph -> Fuel -> Node -> CommandRefusal -> Note
refusedNote g fuel at refusal =
    Note (refusalCode refusal) (failure.what <> " - " <> failure.why) failure.fix
  where
    failure = explainRefusal g fuel at refusal

-- | A command's refusal, as the reader acts on it: what, why, and the command to run instead.
explainRefusal :: OpenGraph -> Fuel -> Node -> CommandRefusal -> Failure
explainRefusal g fuel at = \case
    FoldRefused refusal -> explain g fuel at refusal
    FileUnreadable path ->
        Failure
            BadInput
            ("file_unreadable " <> Text.pack (absPathText path))
            "it does not exist, or may not be read"
            "write it first, or name the file at its path"
    UnknownEvent ref ->
        Failure
            BadInput
            ("event " <> eventRefText ref)
            "no run in the store has such a line"
            "name a line state dump <run> prints"

{- | A refusal of the fold, as the reader acts on it: what, why, and the
command to run instead, from the edges out of where the run is that the
run's Fuel would take: a hand-back is never named, as its hand-back records it.
-}
explain :: OpenGraph -> Fuel -> Node -> Refusal -> Failure
explain g fuel at = \case
    NotStarted -> notStarted
    StartedTwice -> refused "started" "the run has started already" "state next"
    OtherRun run ->
        refused
            "the line"
            ("it is run " <> runIdText run <> "'s, not this log's")
            "state show"
    AfterStop stop ->
        refused
            "the event"
            ("the run stopped: " <> reasonText stop.reason <> " " <> stop.why)
            "state init --notes <a new dir>"
    NoEdge _ event -> refused (eventText event) ("no such arrow out of " <> atText at) records
    NotSkippable _ -> refused "the skip" "this Fuel never skips the block" "state next"
    OutOfBudget cap allowed ->
        refused
            ("the spend at " <> atText at)
            ( someMeterName cap.meter
                <> " allows "
                <> tshow allowed
                <> " at this Fuel, all spent"
            )
            ( atPlace
                (\place -> Text.intercalate " | " (map (.command) (capRecords g place cap.atCap)))
            )
    StillOpen open ->
        refused
            ("leaving " <> atText at)
            (tshow open <> " spawned here have yet to hand back")
            "state next"
    NothingToExtend ->
        refused
            "extend"
            ("the run is at " <> atText at <> ", where no budget asks the user to go on")
            "state next"
    TargetOffFuel ->
        refused
            "target"
            ( "the run is at "
                <> atText at
                <> ": a target is named at a chief run's request Fuel, before its level"
            )
            "state show"
    NoSingleState (StateName name) ->
        refused
            ("override to " <> name)
            "the flow has no single state of that name"
            ("state override <" <> Text.intercalate "|" stateNames <> "> <why>")
    AskedTwice qid -> refused (qidText qid) "it was asked already" "state pending"
    NotPending qid -> refused (qidText qid) "no such question is pending" "state pending"
    AlreadyForwarded qid ->
        refused
            (qidText qid)
            "it was forwarded: only its answer is left"
            ("state answer " <> qidText qid <> " <answer>")
    NotForwarded qid ->
        refused
            (qidText qid)
            "it was never forwarded: this run rules on it or forwards it"
            (triage (qidText qid))
    IsParked qid ->
        refused
            (qidText qid)
            "it is parked: only its answer is left"
            ("state answer " <> qidText qid <> " <answer>")
    AnsweredOtherwise qid earlier ->
        refused
            ("another answer to " <> qidText qid)
            ("it was answered already: " <> replyWords earlier)
            "state show"
    NotAllowed refusal -> case refusal of
        Ask.MayNotRule _ kind ->
            refused
                ("a ruling on " <> kindName kind)
                ("this run forwards a " <> kindName kind <> " question")
                "state forward <qid>"
        Ask.MustAnswer _ kind ->
            refused
                ("a forward of " <> kindName kind)
                ("this run answers a " <> kindName kind <> " question itself")
                (triage "<qid>")
        Ask.NeverAskedOf _ kind ->
            refused (kindName kind) "such a question never reaches this run" "state pending"
        Ask.NoBasis qid ->
            refused
                ("a ruling on " <> qidText qid)
                "a Security ruling names its basis"
                (rule (qidText qid) <> " --basis <event-id>|obvious:<why>")
    NotAbove _ ->
        refused
            "the answer"
            "only whoever started the run answers it"
            "state answer <qid> <answer>"
    FanRefused refusal -> case refusal of
        Fan.UnknownTask task ->
            refused
                ("task " <> Codec.taskIdText task)
                "the breakdown has no such task"
                "state show"
        Fan.StillRunning task child ->
            refused
                ("a child for task " <> Codec.taskIdText task)
                ("child " <> runIdText child <> " still runs it")
                "state next"
        Fan.SpawnedTwice child -> refused ("child " <> runIdText child) "it was spawned already" "state next"
        Fan.UnknownChild child ->
            refused
                ("the hand-back of " <> runIdText child)
                "no such child was spawned"
                "state show"
        Fan.ChildOver child ->
            refused
                ("the hand-back of " <> runIdText child)
                "the child finished or stopped already"
                "state next"
        Fan.Unsettled tasks ->
            refused
                "the fan-out's end"
                ("tasks not settled: " <> Text.unwords (map Codec.taskIdText (toList tasks)))
                "state next"
        Fan.AtWork task ->
            refused
                ("an agent for task " <> Codec.taskIdText task)
                "one works on it already, until its child hands back"
                "state next"
        Fan.StopUntriaged child ->
            refused
                ("a retry of child " <> runIdText child)
                "its stop is not triaged yet"
                ("state ask --kind <kind> --from " <> runIdText child <> " <question>")
        Fan.AwaitsUser child ->
            refused
                ("a retry of child " <> runIdText child)
                "its question is open: the retry waits for the answer"
                "state next"
        Fan.Busy tasks ->
            refused
                "a new breakdown"
                ( "an agent is at work on tasks: "
                    <> Text.unwords (map Codec.taskIdText (toList tasks))
                )
                "state next"
        Fan.Unmerged tasks ->
            refused
                "the round's end"
                ( "tasks neither merged, kept, delivered nor parked: "
                    <> Text.unwords (map Codec.taskIdText (toList tasks))
                )
                "state next"
        Fan.NotARound task ->
            refused
                ("task " <> Codec.taskIdText task <> " kept")
                "only a round on an existing PR is kept: merge or park it"
                "state show"
        Fan.NotItsRound task url ->
            refused
                ("task " <> Codec.taskIdText task <> " kept")
                ("its round is on " <> Codec.urlText url <> ": only that PR is kept")
                ( "state record task "
                    <> Codec.taskIdText task
                    <> " "
                    <> Codec.taskStateArgs (Kept url)
                )
        Fan.TaskExists task ->
            refused
                ("task " <> Codec.taskIdText task)
                "the fan-out has a task of that id already"
                "state show"
        -- Its own message, under the code a dependency on a later task has: unknown_task.
        Fan.BaseNotEarlier task base ->
            refused
                "unknown_task"
                ( "task "
                    <> Codec.taskIdText task
                    <> " cannot have base "
                    <> Codec.taskIdText base
                    <> ": a base names an earlier task of the breakdown"
                )
                "state show"
    NotAtFan ->
        refused
            "the child's or task's event"
            ("the run is at " <> atText at <> ", no fan-out's state")
            "state show"
    NotOneHolder task requests -> case requests of
        [] ->
            refused
                ("task " <> Codec.taskIdText task)
                "no request's breakdown has such a task"
                "state show"
        holding ->
            refused
                ("task " <> Codec.taskIdText task)
                ( "requests "
                    <> Text.unwords (map taskNoText holding)
                    <> " each have such a task in their breakdown"
                )
                "state tasks"
    NotVoidable n ->
        refused
            ("seq " <> tshow n)
            "no line the run replays has it: none does, it is voided, or it is a void"
            "state void <the seq of an event state dump prints> <why>"
    NoFocus ->
        refused
            "the request switch"
            "only a chief run going on switches requests"
            "state next"
    NotInFocus task ->
        refused
            ("the suspension of " <> taskNoText task)
            "it is not the request in focus"
            "state tasks"
    NotSuspended task ->
        refused
            ("the focus on " <> taskNoText task)
            "it is not a waiting request"
            "state tasks"
    FocusRecorded task ->
        refused
            ("the turn away from " <> taskNoText task)
            "it recorded work: it is suspended first"
            "state focus [<request>] --summary <where it stands>"
    UnknownGap n ->
        refused
            ("gap " <> tshow n)
            "the run logged no gap at this seq"
            "state show lists the run's gaps"
    GapClosed n closure ->
        refused
            ("gap " <> tshow n)
            ( "it closed already, "
                <> case closure of
                    Gap.Fixed pr -> "fixed by " <> uriText pr
                    Gap.WontFix why -> "won't fix: " <> Ask.oneLineText why
            )
            "state record gap \"<text>\" --evidence <run:seq of this gap>, if it came back"
    VoidBreaks n refusal ->
        let broken = explain g fuel at refusal
         in refused
                ("the void of " <> tshow n)
                ("the log without it does not replay: " <> broken.what <> " - " <> broken.why)
                "state void <the later line that needs it> <why>, then this one"
    SpanNotOpen (SpanId n) ->
        refused
            ("the end of span " <> tshow n)
            "the span is not open: it never started, ended already, or a restart lost it"
            "state show"
    EpicRefused refusal -> case refusal of
        Epic.EpicExists epic ->
            refused
                "epic_exists"
                ("the run opened epic " <> epicNameText epic <> " already")
                "state resume"
        Epic.EpicNotOpen epic ->
            refused
                "epic_not_open"
                ( "epic "
                    <> epicNameText epic
                    <> " is ready or merged already: only an open epic is made ready"
                )
                "state resume"
        Epic.EpicNotReady epic ->
            refused
                "epic_not_ready"
                ( "epic "
                    <> epicNameText epic
                    <> " is not ready for review: it is open still, or merged already"
                )
                ( "state epic ready "
                    <> epicNameText epic
                    <> " --pr <url>, once its final PR is open"
                )
        Epic.UnknownEpic epic ->
            refused
                "unknown_epic"
                ("the run never opened epic " <> epicNameText epic)
                ( "state epic open "
                    <> epicNameText epic
                    <> " --repo <owner/name> --branch <branch>"
                )
  where
    refused = Failure BadInput
    records = atPlace $ \place -> case [ recordCommand event
                                       | (event, _) <- shownEdges g place
                                       , fuelTakes fuel place.name event
                                       , event.outcome /= handedBackOutcome
                                       ] of
        [] -> "state show"
        commands -> Text.intercalate " | " commands
    atPlace fix = case at of
        At place -> fix place
        Out -> "state show"
        Exit -> "state show"
    stateNames = map (stateNameText . placeName) (Set.toList (places g))
    rule qid = "state rule " <> qid <> " --answer <a> --why <w> --cost <c>"
    triage qid = rule qid <> " | state forward " <> qid

{- | The code of a refusal, by its constructor (#552's Appendix B, Signals).
A wrapper gives its inner refusal's code; a void that breaks the log is
@void_breaks@ whatever it breaks. No arm is @_@: a new constructor needs its
own code before it builds.
-}
refusalCode :: CommandRefusal -> RefusalCode
refusalCode =
    RefusalCode . \case
        FoldRefused refusal -> case refusal of
            NotStarted -> "not_started"
            StartedTwice -> "started_twice"
            OtherRun {} -> "other_run"
            AfterStop {} -> "after_stop"
            NoEdge {} -> "no_edge"
            NotSkippable {} -> "not_skippable"
            OutOfBudget {} -> "out_of_budget"
            StillOpen {} -> "still_open"
            NothingToExtend -> "nothing_to_extend"
            TargetOffFuel -> "target_off_fuel"
            NoSingleState {} -> "no_single_state"
            AskedTwice {} -> "asked_twice"
            NotPending {} -> "not_pending"
            AlreadyForwarded {} -> "already_forwarded"
            NotForwarded {} -> "not_forwarded"
            IsParked {} -> "is_parked"
            AnsweredOtherwise {} -> "answered_otherwise"
            NotAllowed inner -> case inner of
                Ask.MayNotRule {} -> "may_not_rule"
                Ask.MustAnswer {} -> "must_answer"
                Ask.NeverAskedOf {} -> "never_asked_of"
                Ask.NoBasis {} -> "no_basis"
            NotAbove {} -> "not_above"
            FanRefused inner -> case inner of
                Fan.UnknownTask {} -> "unknown_task"
                Fan.StillRunning {} -> "still_running"
                Fan.SpawnedTwice {} -> "spawned_twice"
                Fan.UnknownChild {} -> "unknown_child"
                Fan.ChildOver {} -> "child_over"
                Fan.Unsettled {} -> "unsettled"
                Fan.AtWork {} -> "at_work"
                Fan.StopUntriaged {} -> "stop_untriaged"
                Fan.AwaitsUser {} -> "awaits_user"
                Fan.Busy {} -> "busy"
                Fan.Unmerged {} -> "unmerged"
                Fan.NotARound {} -> "not_a_round"
                Fan.NotItsRound {} -> "not_its_round"
                Fan.TaskExists {} -> "task_exists"
            NotAtFan -> "not_at_fan"
            NotOneHolder {} -> "not_one_holder"
            NotVoidable {} -> "not_voidable"
            VoidBreaks {} -> "void_breaks"
            NoFocus -> "no_focus"
            NotInFocus {} -> "not_in_focus"
            NotSuspended {} -> "not_suspended"
            FocusRecorded {} -> "focus_recorded"
            UnknownGap {} -> "unknown_gap"
            GapClosed {} -> "gap_closed"
            SpanNotOpen {} -> "span_not_open"
        FileUnreadable {} -> "file_unreadable"
        UnknownEvent {} -> "unknown_event"

-- | Where the run is, by its state's name.
atText :: Node -> Text
atText = \case
    At place -> stateNameText (placeName place)
    Out -> "the end"
    Exit -> "the end"

{- | An event the grammar lacks, at a run: refused with the events the run's
Fuel takes where it is, an @extend@ too where a budget here grants one. A
hand-back is listed even with no child open: the name is what the reader lacks.
At a fork of child runs nothing is recorded: the fix is the child's brief.
-}
unknownEvent :: OpenGraph -> RunState -> Text -> Failure
unknownEvent g state name = case Fold.forkingAt g state of
    Just _ ->
        Failure
            BadInput
            ("no event " <> name)
            ( "at "
                <> atText state.at
                <> ", run "
                <> spawnChildOption.command
                <> ", then "
                <> spawnChildOption.means
            )
            spawnChildOption.command
    Nothing ->
        Failure
            BadInput
            ("no event " <> name)
            ("at " <> atText state.at <> " the run takes " <> listed (map fst events))
            (closest name events)
  where
    events =
        edgeEvents
            <> [(extend.name, extendOption.command) | not (null (Fold.extendable g state))]
    edgeEvents = case state.at of
        At place ->
            [ (eventText event, recordCommand event)
            | (event, _) <- shownEdges g place
            , fuelTakes (Fold.fuelOf state) place.name event
            ]
        Out -> []
        Exit -> []
    listed = \case
        [] -> "none"
        names -> Text.intercalate ", " names

-- | An event the grammar lacks, with no run to say where it is: every event, and the help.
anyEvent :: Text -> Failure
anyEvent name =
    Failure
        BadInput
        ("no event " <> name)
        ("the events are " <> Text.intercalate ", " (map (.name) recordables))
        "state help"

{- | The command of the one event of the step the name starts with, as
@gather.bogus@ names @gather.enough@; else of the only event; else @state next@.
-}
closest :: Text -> [(Text, Text)] -> Text
closest name events = case (sameStep, events) of
    ([(_, command)], _) -> command
    (_, [(_, command)]) -> command
    _ -> "state next"
  where
    sameStep = case Text.breakOn "." name of
        (_, "") -> []
        (step, _) -> [e | e@(event, _) <- events, (step <> ".") `Text.isPrefixOf` event]

{- | The task's latest child, whose stop awaits triage, while a retry is
left ('Fan.retryLeft'): what @state retry@ triages and retries.
-}
retryOf :: RunState -> TaskId -> Either Failure (Task, Child, Stop)
retryOf state task = case ( Fan.lookupTask fan task
                          , lookup
                                (Tasked task)
                                [(Fan.childTaskId child, stopped) | stopped@(child, _) <- Fan.untriaged fan]
                          ) of
    (Nothing, _) -> Left (refused "the breakdown has no such task" "state show")
    (Just _, Nothing) -> Left (refused "no stopped child of it awaits triage" "state next")
    (Just _, Just (child, _))
        | not (Fan.retryLeft fan task) ->
            Left
                ( refused
                    (tshow (Fan.tries fan task) <> " children tried it, its one retry is spent")
                    ( "state ask --kind Stuck --from "
                        <> runIdText child.run
                        <> " <question> | state record task "
                        <> Codec.taskIdText task
                        <> " parked <why>"
                    )
                )
    (Just found, Just (child, stop)) -> Right (found, child, stop)
  where
    fan = Fold.currentFan state
    refused = Failure BadInput ("task " <> Codec.taskIdText task)

{- | A question its asker has not open already, and the run has no answer
to: the same one again would wait twice on one answer, or again on one
given. An answer has no asker, so its text alone matches. Checked when
asked, never in the fold, so a log that repeated one still replays.
-}
notOpenYet :: RunState -> Asker -> OneLine -> Either Failure ()
notOpenYet state from text = case ( [ p.asking.question.qid
                                    | p <- state.pending
                                    , p.asking.from == from
                                    , p.asking.question.text == text
                                    ]
                                  , [answer | answer <- state.answers, answer.about.text == text]
                                  ) of
    (qid : _, _) -> Left (refused ("it is open already as " <> qidText qid))
    ([], answer : _) ->
        Left
            ( refused
                ( "it is answered already as "
                    <> qidText answer.about.qid
                    <> ": "
                    <> Ask.replyText answer.about.kind answer.given
                )
            )
    ([], []) -> Right ()
  where
    refused why = Failure BadInput "the question" why "state next"

{- | A question to answer: one open, or one answered already, whose answer
again the fold judges (the same one is no news).
-}
answeredQid :: RunState -> Text -> Either Failure QId
answeredQid state raw = case parseQId raw of
    Just qid | Just _ <- Fold.heldAnswer state qid -> Right qid
    _ -> openQid state raw

{- | A question the run has open, by the id typed: a malformed one or one
not open is refused with the open ones listed.
-}
openQid :: RunState -> Text -> Either Failure QId
openQid state raw = case parseQId raw of
    Just qid | qid `elem` open -> Right qid
    _ -> Left (Failure BadInput ("question " <> raw) why "state pending")
  where
    open = [p.asking.question.qid | p <- state.pending]
    why = case open of
        [] -> "no question is open"
        _ -> "it is not open; open: " <> Text.unwords (map qidText open)
