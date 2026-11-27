{- | The effect shell of @state@: read the worktree, git and GitHub, decide
in pure code, then append to the log and print. Every decision is the
kernel's; this module moves data between them and the effects, whose IO
interpreters 'runShellIO' runs.
-}
module State.Cli.Shell (Shell, main, hook, runShellIO, storeDurability, recordedEvent) where

import Control.Applicative ((<|>))
import Control.Exception (IOException)
import Control.Monad ((<=<))
import Control.Monad qualified as Monad
import Data.Bifunctor qualified as Bifunctor
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Either (fromRight, partitionEithers)
import Data.Foldable (for_, toList, traverse_)
import Data.Functor (($>), (<&>))
import Data.List (find, genericLength)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, listToMaybe, maybeToList)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (
    decodeUtf8,
    decodeUtf8',
    decodeUtf8Lenient,
    encodeUtf8,
 )
import Data.Time (UTCTime)
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Error.Static (Error, catchError, runErrorNoCallStack)
import Effectful.Exception (throwIO, try, tryJust)
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
import Effects.Log (Appending (..), Log, eventsOnly, runLogIO, shipped)
import Effects.Log qualified as Log
import Effects.Random (Random, randomBytes, runRandomIO)
import Effects.Store.Connection (
    Durability (..),
    Foreign (..),
    OpenRefusal (..),
 )
import Effects.Store.Migration (applicationId)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Options.Applicative qualified as Optparse
import State.Artifact (
    AbsPath,
    Artifact (..),
    Blob (..),
    Contents (..),
    FileArtifact (..),
    FileKind (TaskList, Transcript),
    FileRef (..),
    Size (..),
    Snapshot (..),
    absPath,
    absPathText,
    blobsOf,
    digestText,
    fileKindText,
    keepsContent,
    newest,
    originRepo,
    register,
    resnapshot,
    snapshotted,
    uriText,
    urlKindText,
 )
import State.Category.Flow (Name)
import State.Category.Fuel (Fuel (Balanced), PerFuel, SkipWhen)
import State.Category.Graph (Node (..), OpenGraph (..), placeName)
import State.Category.Step (StateName, stateNameText)
import State.Cli.Command (
    Block (..),
    BriefPart (..),
    Command (..),
    CommandRefusal (..),
    Exit (..),
    Failure (..),
    InitArgs (..),
    Location (..),
    Origin (..),
    Raise (..),
    RunCommand (..),
    Until (..),
    Usage (..),
    answeredQid,
    anyEvent,
    architectInitFix,
    chiefInitFix,
    defaultFlow,
    explain,
    explainRefusal,
    failureText,
    help,
    initFix,
    notOpenYet,
    notStarted,
    openQid,
    optparseText,
    outsideRunTree,
    parseCommand,
    parseHook,
    refusalCode,
    refusedNote,
    retryOf,
    sqlRefused,
    tenXInitFix,
    unknownEvent,
 )
import State.Cli.Render qualified as Render
import State.Cli.Render.Mermaid (mermaid)
import State.Cli.Resume qualified as Resume
import State.Cli.Route (
    StateCall (..),
    Target (..),
    cdThen,
    leadOf,
    route,
    stateCalls,
 )
import State.Cli.Route qualified as Route
import State.Cli.View (
    beginText,
    brief,
    briefSection,
    epicRow,
    pendingLines,
    showRun,
    taskBrief,
 )
import State.Cli.View qualified as View
import State.FlowName (fixedFuel)
import State.Protocol.Advice (
    Action (AwaitAnswer, AwaitOn, Triage),
    Advice (..),
    Facts (..),
    PullRequest (..),
    advise,
    changedLinesOf,
    deliver,
    deliverMore,
    deliverPrompt,
    due,
    explained,
    handsBack,
    ownAsk,
    pullRequestOf,
    skippable,
 )
import State.Protocol.Advice qualified as Advice
import State.Protocol.Binding (
    AgentId (..),
    Binding (..),
    Key (..),
    Slot,
    SpanLink (..),
    Worktree (..),
    bindingFile,
    bindingIn,
    leadFile,
    ledFile,
    rebound,
    renderBinding,
    renderSpanLink,
    resolve,
    sessionDir,
    slotOf,
    slottedAgents,
    spanFile,
    spanLinkIn,
    staleNote,
    stashFile,
    stopFile,
    storeRoot,
 )
import State.Protocol.Handback (
    Handback (..),
    Refusal (..),
    Typed (..),
    areaNames,
    handbackEnding,
    parseHandback,
    refusalText,
    typeDirectHandback,
    typeHandback,
 )
import State.Protocol.Handback qualified as Handback
import State.Protocol.Hook (
    Bind (..),
    Call (..),
    Delivery (..),
    End (..),
    Gate (..),
    HookName (..),
    Job (..),
    LeadSkill,
    Reply (..),
    Spawn (..),
    StartSource (..),
    ToolCallId,
    Want (..),
    aboutKnown,
    aboutRun,
    callOf,
    delivery,
    encodeReply,
    followedAt,
    hookName,
    hookSources,
    initSession,
    keyOf,
    leadSkill,
    leadSkillName,
    loggedAlready,
    offAdvice,
    parseHookEvent,
    replyOf,
    restartOf,
    sessionOf,
    silent,
    spanEndedSource,
    spanOfCall,
    spanStartOf,
    spanStartedSource,
    spawnedAt,
    toldOf,
    wants,
 )
import State.Protocol.Hook qualified as Hook
import State.Protocol.Record (Option (..), Recording (..))
import State.Role (RoleDef (..), SomeFlow (..), graphOf)
import State.Role qualified as Role
import State.Run.Ask (
    Above (ParentRun),
    ChildTask (..),
    Link (..),
    OneLine,
    Parent (..),
    Principal (..),
    Proposal (..),
    QId (..),
    Question (..),
    kindName,
    oneLineText,
    qidText,
 )
import State.Run.Ask qualified as Ask
import State.Run.Card qualified as Card
import State.Run.Codec (
    eventType,
    reasonText,
    taskIdText,
 )
import State.Run.Codec qualified as Codec
import State.Run.Event (
    AgentRole (..),
    Asker (..),
    Asking (..),
    Base (OnEpic),
    Child (..),
    DraftPr (..),
    Envelope (..),
    EpicMove (..),
    EpicName,
    Event (..),
    FlowName (..),
    Handover,
    NonBlank,
    Note (..),
    RefusalCode (..),
    Repo,
    RunId,
    Session (..),
    SessionId (..),
    Sha,
    Source (..),
    SpanEnding (NoHandback),
    SpanId (..),
    Start (..),
    Task (..),
    TaskId,
    TaskNo,
    Waiting (Ci),
    artifactsOf,
    parseRunId,
    parseSessionId,
    placeOf,
    roleText,
    runIdText,
    spansOf,
    stepTook,
    taskNoText,
 )
import State.Run.Event qualified as Event
import State.Run.Fan qualified as Fan
import State.Run.Fold (
    Append (..),
    Pending (asking, waits),
    RunState (..),
    Waits (..),
    askedAt,
    replay,
 )
import State.Run.Fold qualified as Fold
import State.Run.Gap (Evidence (..), GapArea (..), GapMove)
import State.Run.Gap qualified as Gap
import State.Run.Id (EventRef (..), digestOf, eventRefText, numberedText)
import State.Show (tshow)
import State.Step.Artifact (
    PlanCall (ChildConfirms, ParentDecided),
    Shape (..),
    shellPathText,
    shellWord,
 )
import State.Step.Catalog (outcome, termSkips)
import State.Step.Fuel (Outcome (LevelSet))
import State.Step.Request (Outcome (NextRequest))
import State.Table (Steps, parseSteps)
import System.Exit (ExitCode (..))
import System.FilePath (equalFilePath, takeDirectory, (</>))
import System.IO.Error (isDoesNotExistError)

{- | Every effect the shell runs on. A run store it cannot open is an
'OpenRefusal' it tells as a failure.
-}
type Shell es =
    ( Clock :> es
    , Console :> es
    , Environment :> es
    , Error OpenRefusal :> es
    , Gh :> es
    , Git :> es
    , Log :> es
    , Random :> es
    , RoFileSystem :> es
    , WrFileSystem :> es
    )

-- | A shell program against the real world: the process, its files, git and GitHub.
runShellIO ::
    Durability ->
    Eff
        '[ Random
         , Log
         , Error OpenRefusal
         , Git
         , Gh
         , WrFileSystem
         , RoFileSystem
         , Environment
         , Console
         , Clock
         , IOE
         ]
        a ->
    IO a
runShellIO durability =
    either told pure
        <=< runEff
            . runClockIO
            . runConsoleIO
            . runEnvironmentIO
            . runFileSystemIO
            . runGhIO
            . runGitIO
            . runErrorNoCallStack
            . runLogIO shipped durability
            . runRandomIO
  where
    -- 'main' and 'hook' tell each refusal themselves: one past them is a bug.
    told refusal = ioError (userError ("an untold store refusal: " <> show refusal))

{- | The run store's durability and the rest of argv: 'Unsynced' when argv
opens with the hidden @--store-durability unsynced@, which only the test
suite passes, for its throwaway stores; 'Full' otherwise.
-}
storeDurability :: [Text] -> (Durability, [Text])
storeDurability = \case
    "--store-durability" : "unsynced" : argv -> (Unsynced, argv)
    argv -> (Full, argv)

-- | Run one command from argv; a failure goes to stderr with its exit code.
main :: (Shell es) => [Text] -> Eff es ExitCode
main argv =
    loadSteps >>= \case
        Left failure -> failed "steps" failure
        Right steps -> case parseCommand steps argv of
            Left said -> usageOut "state" said
            Right (sub, parsed) ->
                either (pure . Left) (outageAware . refusalAware . execute steps) parsed >>= \case
                    Right out -> Console.out out $> ExitSuccess
                    Left failure -> failed sub failure
  where
    failed sub failure =
        Console.err (failureText sub failure) $> case failure.exit of
            BadInput -> ExitFailure 2
            Outage -> ExitFailure 1
            NotStored -> ExitFailure 3
            NotAnArtifact -> ExitFailure 4

-- | Help asked for goes to stdout, exit 0; a usage error to stderr, exit 2.
usageOut :: (Console :> es) => String -> Usage -> Eff es ExitCode
usageOut program (Usage failure) = case Optparse.renderFailure failure program of
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
                    Left failure ->
                        Console.err (failureText ("hook " <> hookName name) failure) $> ExitFailure 1
                    Right steps -> case wants steps name event of
                        Left why -> usage why
                        Right Nothing -> pure ExitSuccess
                        Right (Just job) -> do
                            said <-
                                try
                                    ( refusalAware (Right <$> jobReply steps name input (callOf event) job)
                                        <&> either (toldOf job . failureText ("hook " <> hookName name)) id
                                    )
                            -- aeson encodes UTF-8, so the reply decodes whole.
                            traverse_ (Console.out . decodeUtf8 . LBS.toStrict) . encodeReply $ case said of
                                Right reply -> reply
                                Left e -> toldOf job (hookError name e)
                            pure ExitSuccess
  where
    usage line = Console.err (line <> "\n") $> ExitFailure 2

{- | A hook's reply to its job: how work begins needs no run, a lead skill
marking its agent a lead; a route denies a write where the caller's run is
read-only, a @state@ call at another run than the caller's, and an unbound
lead's write; the rest is what the caller's run says. A disk or git error is context naming the run once one is
known: the bound one, then the one found. One before either, such as reading
the caller's binding, names none, as no run is known yet.
-}
jobReply ::
    (Shell es) => Steps -> HookName -> BS.ByteString -> Call -> Job -> Eff es Reply
jobReply steps name input call job = case job of
    Begins begin -> do
        (marked, run) <- case begin of
            Hook.TypedSkill skill -> (,Nothing) <$> markLead call skill
            Hook.CalledSkill skill -> (,Nothing) <$> markLead call skill
            Hook.SpawnedLead -> pure ("", Nothing)
            Hook.SpawnedWorker _ -> ("",) <$> workedRun
        pure (replyOf job (beginText steps run begin <> marked))
    Routes (RunsShell command)
        | Just _ <- call.agent
        , Just why <- Route.parentlessInit steps command ->
            pure (Deny why)
    Routes gate ->
        callerBinding call >>= \(slot, bound) -> case (bound, gate) of
            (Just binding, _) ->
                readOnlyAt binding.run gate >>= \case
                    Just why -> pure (Deny why)
                    Nothing -> case gate of
                        RunsShell command -> case stateCalls steps call.cwd command of
                            [] -> pure Quiet
                            calls ->
                                standing binding >>= \case
                                    (_, Standing) ->
                                        maybe Quiet Deny . route binding
                                            <$> traverse (\c -> (c,) <$> targetAt c.dir) calls
                                    -- A removed worktree's run is done: no call strays from it.
                                    (_, Removed) -> pure Quiet
                        Edits _ -> pure Quiet
                        Writes _ -> pure Quiet
                        Spawns -> pure Quiet
            (Nothing, _) -> do
                began <-
                    maybe
                        (pure Nothing)
                        (fmap (leadSkill . Text.strip =<<) . FileSystem.readText . leadFile)
                        slot
                pure
                    (maybe Quiet Deny (Route.gate (leadOf ((.role) =<< call.agent) began) gate))
    Asks want ->
        callerBinding call >>= \(slot, bound) ->
            replyOf job
                <$> telling
                    name
                    ((.run) <$> bound)
                    (wantAnswer steps name input call want slot bound)
    Binds bind ->
        callerBinding call >>= \(slot, bound) ->
            replyOf job
                <$> telling name ((.run) <$> bound) (bindAnswer steps name call bind slot bound)
    Ends end -> replyOf job <$> agentsEnded steps input call end

{- | Why the bound run denies the call where it is: by the flow running
there. Read under the log's lock, appending nothing; no git is read, as a
route runs before every edit. The run is replayed, as a scope inside it may
run another flow, unless its first line starts a flow that writes code in
every scope: an engineer's or a 10x's route reads one line, however long its
log. A run that is gone or does not replay denies nothing: its other hooks
tell what is wrong with it.
-}
readOnlyAt ::
    (Clock :> es, Environment :> es, Git :> es, Log :> es) =>
    RunId -> Gate -> Eff es (Maybe Text)
readOnlyAt run gate =
    Log.firstEvent run >>= \first -> case startedFlow =<< first of
        Just flow | mayDeny flow -> denialAt
        _ -> pure Nothing
  where
    startedFlow =
        either
            (const Nothing)
            (fmap (.flow) . Fold.runStart . (.event))
    denialAt =
        onRunLog
            ( \_ loaded ->
                ( []
                , Right
                    ( Route.readOnly
                        loaded.state.start.notes
                        (Role.flowAt loaded.state.start.flow (askedAt loaded.state))
                        gate
                    )
                )
            )
            run
            <&> \case
                Ran (Right denial) -> denial
                Ran (Left _) -> Nothing
                NoRun -> Nothing

-- | Whether a run of this flow may deny a write: some state of its graph runs, by its scopes, a flow that writes no code.
mayDeny :: FlowName -> Bool
mayDeny flow =
    any
        (Route.writesNoCode . Role.flowAt flow . placeName . fst)
        (Map.keys (graphOf flow).edges)

-- | Marks the caller a lead of the skill it began; a disk error is told, the skill begins regardless.
markLead :: (Shell es) => Call -> LeadSkill -> Eff es Text
markLead call skill =
    slotFor call.session (keyOf call.agent) >>= \case
        Just slot ->
            telling
                BeginHook
                Nothing
                ("" <$ writeWhole (leadFile slot) (leadSkillName skill <> "\n"))
        Nothing -> pure ""

-- | What an act says; a disk or git error is its text too, naming the run when one is known.
telling :: HookName -> Maybe RunId -> Eff es Text -> Eff es Text
telling name run act = try act <&> either (aboutKnown run . hookError name) id

-- | A disk or git error a hook tells as context: it never fails the agent.
hookError :: HookName -> IOException -> Text
hookError name e = "state hook " <> hookName name <> ": " <> tshow e

-- | The caller's slot in the session's bindings, and the binding it holds.
callerBinding ::
    (Environment :> es, RoFileSystem :> es) =>
    Call -> Eff es (Maybe Slot, Maybe Binding)
callerBinding call = do
    slot <- slotFor call.session (keyOf call.agent)
    (slot,) <$> slotBinding slot

-- | The binding a slot holds, if any.
slotBinding :: (RoFileSystem :> es) => Maybe Slot -> Eff es (Maybe Binding)
slotBinding = maybe (pure Nothing) (readBinding . bindingFile)

-- | A binding, and whether its worktree stands: git finds none there once it is removed.
standing ::
    (Git :> es, RoFileSystem :> es) => Binding -> Eff es (Binding, Worktree)
standing binding = (binding,) . maybe Removed (const Standing) <$> toplevelAt binding.toplevel

{- | The top of the git worktree a directory is in; none for one in no
worktree, or no directory. Only entering the directory may fail as gone: git
failing to start throws too, a missing binary as does-not-exist, so it is
caught apart and rethrown, a fault to tell, never a removed worktree.
-}
toplevelAt ::
    (Git :> es, RoFileSystem :> es) => FilePath -> Eff es (Maybe FilePath)
toplevelAt dir =
    tryJust
        (Monad.guard . isDoesNotExistError)
        (FileSystem.inDirectory dir (try Git.toplevel))
        >>= \case
            Right (Right (Right top)) -> pure (Just top)
            Right (Right (Left _)) -> pure Nothing
            Right (Left (e :: IOException)) -> throwIO e
            Left () -> pure Nothing

{- | The worktree a directory is in, with the parent of the run its pointer
names; none for a directory in no worktree.
-}
targetAt ::
    (Git :> es, Log :> es, RoFileSystem :> es) => FilePath -> Eff es (Maybe Target)
targetAt dir =
    toplevelAt dir
        >>= traverse
            (\top -> Target top <$> FileSystem.inDirectory top (fmap parentOf pointedRun))
  where
    parentOf = \case
        Nothing -> Nothing
        Just (Left _) -> Nothing
        Just (Right started) -> Fold.runStart started.event >>= parentRun . (.principal)

-- | The run that started a run, if a run did.
parentRun :: Principal -> Maybe RunId
parentRun = \case
    ByRole parent _ _ -> Just parent.run
    ByUser _ -> Nothing
    ByCaller _ -> Nothing

-- | What a want says at the run its caller is bound to ("State.Protocol.Binding"), or where it waits ('delivery').
wantAnswer ::
    (Shell es) =>
    Steps ->
    HookName ->
    BS.ByteString ->
    Call ->
    Want ->
    Maybe Slot ->
    Maybe Binding ->
    Eff es Text
wantAnswer steps name input call want slot bound = do
    linked <- slotSpan slot
    case delivery want (keyOf call.agent) slot bound linked of
        Stash at -> do
            -- Stashed before the binding and span are read again, as the spawner's hook links
            -- them before it reads the stash: whichever runs second sees the other's file.
            writeWhole (stashFile at) (decodeUtf8Lenient input)
            boundNow <- readBinding (bindingFile at)
            relinked <- slotSpan (Just at)
            case delivery want (keyOf call.agent) slot boundNow relinked of
                Stash _ -> pure ""
                ToRun -> replayStash steps name at
        ToRun -> wantAt steps name call want bound linked

{- | A want where it goes: a subagent's hand-back off the flow to the span it
ends, every other to the caller's run.
-}
wantAt ::
    (Shell es) =>
    Steps ->
    HookName ->
    Call ->
    Want ->
    Maybe Binding ->
    Maybe SpanLink ->
    Eff es Text
wantAt steps name call want bound linked = case want of
    SpanHandback message usage ->
        maybe (pure "") (endLinked call.session (endingOf message) usage) linked
    Hook.HandedBack {} -> atRun steps name call want bound
    ResumeRun _ -> atRun steps name call want bound
    SpawnRole _ _ -> atRun steps name call want bound
    StartsSpan _ -> atRun steps name call want bound

-- | How a hand-back of this text ends its agent's span: by the token its line 1 opens with, if any.
endingOf :: Text -> SpanEnding
endingOf message =
    handbackEnding (either (const Nothing) (.token) (parseHandback message)) message

{- | Ends the span so, logged once ('spanEndedSource') and only while it is
open ('Fold.endSpan'): what was recorded, or why not.
-}
endLinked ::
    (Shell es) =>
    Maybe SessionId -> SpanEnding -> Event.Usage -> SpanLink -> Eff es Text
endLinked session spanEnding usage link =
    either (aboutRun link.run . failureText "span") (.text) <$> onLog end link.run
  where
    end stamp run =
        record
            (Stamp stamp.ts stamp.head session)
            run
            [spanEndedSource link.run link.spanId]
            ( Right
                ( Plan
                    (maybeToList (Fold.endSpan run.state link.spanId spanEnding usage))
                    (\_ written -> printed (aboutRun link.run (recordedLines written)))
                )
            )

-- | The span a slot's agent is linked to, if any.
slotSpan :: (RoFileSystem :> es) => Maybe Slot -> Eff es (Maybe SpanLink)
slotSpan = maybe (pure Nothing) (fmap (>>= spanLinkIn) . FileSystem.readText . spanFile)

-- | The span of the caller, if it is a subagent linked to one.
callerSpan ::
    (Environment :> es, RoFileSystem :> es) => Call -> Eff es (Maybe SpanLink)
callerSpan call = slotSpan =<< slotFor call.session (keyOf call.agent)

-- | A bind: the caller to the run its init printed, or a worker it spawned to the caller's run.
bindAnswer ::
    (Shell es) =>
    Steps -> HookName -> Call -> Bind -> Maybe Slot -> Maybe Binding -> Eff es Text
bindAnswer steps name call bind slot bound = case bind of
    BindSelf binding -> telling name (Just binding.run) $ do
        traverse_ (bindSelf binding) slot
        sessionBound steps call binding.run
    BindSpawned child toolCall worker -> do
        -- The spawner's binding as it is: a stale one is told at the worker's hand-back.
        spawner <- boundOrHere call bound
        worktree <- traverse standing spawner
        childSlot <- slotFor call.session (AgentKey child)
        case (worktree, childSlot) of
            (Just (binding, Standing), Just at) -> telling name (Just binding.run) $ do
                -- Linked, then bound, before a stashed hand-back or stop replays, so it ends the span.
                linked <- maybe (pure "") (linkSpan binding.run at) toolCall
                traverse_ (\_ -> writeBinding (bindingFile at) binding) worker
                stashed <- replayStash steps name at
                pure
                    ( aboutRun
                        binding.run
                        ( foldMap
                            ( \role ->
                                "state: "
                                    <> roleText role
                                    <> " "
                                    <> child.agentIdText
                                    <> " works in this run\n"
                            )
                            worker
                        )
                        <> linked
                        <> stashed
                    )
            -- A removed worktree's run is done: it takes no worker.
            (Just (_, Removed), _) -> pure ""
            (Nothing, _) -> pure ""
            (_, Nothing) -> pure ""

{- | The subagent's span, the one this call started in the run, linked in its
slot; nothing when the call started none. Its failure to read is told.
-}
linkSpan :: (Shell es) => RunId -> Slot -> ToolCallId -> Eff es Text
linkSpan run at toolCall =
    onLog (\_ loaded -> ([], Right (spanOfCall run toolCall loaded.logged))) run >>= \case
        Right (Just started) ->
            "" <$ writeWhole (spanFile at) (renderSpanLink (SpanLink run started) <> "\n")
        Right Nothing -> pure ""
        Left failure -> pure (aboutRun run (failureText "bind" failure))

{- | The caller's session started on the run its @state init@ bound it to,
logged once, by the session's own facts ('initSession'). A new session lost
every agent the run had at work, as a fresh start does ('restartOf'): a resume
from a session whose start hook read another worktree's run still sends them
again. Its failure is told.
-}
sessionBound :: (Shell es) => Steps -> Call -> RunId -> Eff es Text
sessionBound steps call run = either (failureText "bind") (const "") <$> onLog start run
  where
    start stamp loaded =
        record
            (Stamp stamp.ts stamp.head call.session)
            loaded
            [Cli, Cli]
            (Right (Plan (started loaded) (\_ _ -> mempty)))
    started loaded = case initSession call loaded.logged of
        Just session ->
            SessionStarted session
                : maybeToList (restartOf steps Startup loaded.state)
        Nothing -> []

-- | The agent bound to the run its own init printed, and marked its lead ('ledFile').
bindSelf :: (WrFileSystem :> es) => Binding -> Slot -> Eff es ()
bindSelf binding slot = do
    writeBinding (bindingFile slot) binding
    writeWhole (ledFile slot) (runIdText binding.run <> "\n")

-- | The caller's binding, else the run of the worktree a lead runs in: the lead may be unbound.
boundOrHere :: (Shell es) => Call -> Maybe Binding -> Eff es (Maybe Binding)
boundOrHere call = \case
    Just binding -> pure (Just binding)
    Nothing ->
        Monad.join <$> traverse runHere (resolve (keyOf call.agent) Nothing call.cwd)

{- | What an agent's stop ends: the stopped agent's span, unless its
hand-back ended it, and its child run ('agentEnded'), and the stopper's
children not running on. A stopper waits on its foreground children, so a
child of its run absent from the agents running ended unseen, as a lead's
stop of its child tells nothing at the child. Each is told only when its log
refuses or does not read.
-}
agentsEnded ::
    (Shell es) => Steps -> BS.ByteString -> Call -> End -> Eff es Text
agentsEnded steps input call = \case
    StopsAgent agent -> stopped (const True) agent
    Stops key running usage -> do
        own <- case key of
            AgentKey agent ->
                (<>)
                    <$> ownStop agent usage
                    <*> agentEnded steps call.session (const True) agent
            Main -> pure ""
        stopper <- boundOrHere call . snd =<< callerBinding call
        unseen <- case stopper of
            Nothing -> pure []
            Just binding -> do
                agents <- sessionAgents call.session
                traverse
                    (stopped (== binding.run))
                    [agent | agent <- agents, agent `notElem` running, AgentKey agent /= key]
        pure (own <> Text.concat unseen)
  where
    stopped under agent =
        (<>)
            <$> spanStopped call.session under agent
            <*> agentEnded steps call.session under agent
    -- A foreground agent stops before its spawner's hook links its span: its stop waits for it.
    ownStop agent usage =
        slotFor call.session (AgentKey agent) >>= \case
            Nothing -> pure ""
            Just at ->
                slotSpan (Just at) >>= \case
                    Just link -> endLinked call.session NoHandback usage link
                    Nothing -> do
                        writeWhole (stopFile at) (decodeUtf8Lenient input)
                        slotSpan (Just at) >>= maybe (pure "") (const (replayStash steps StopHook at))

{- | The agent's span ended with no hand-back, when it is linked to one in a
run this takes and still open. Seen from another agent's hook, its tokens are
unknown.
-}
spanStopped ::
    (Shell es) =>
    Maybe SessionId -> (RunId -> Bool) -> AgentId -> Eff es Text
spanStopped session under agent =
    (slotSpan =<< slotFor session (AgentKey agent)) >>= \case
        Just link | under link.run -> endLinked session NoHandback Event.unreported link
        _ -> pure ""

-- | The subagents with a slot in the session's bindings.
sessionAgents ::
    (Environment :> es, RoFileSystem :> es) => Maybe SessionId -> Eff es [AgentId]
sessionAgents session =
    maybe (pure []) (fmap slottedAgents . FileSystem.listDirectory . sessionDir)
        =<< slotFor session Main

{- | An agent ended with no hand-back, logged once: 'AgentEnded' in the child
run it leads ('ledRun'), when a parent the test takes started it, then in
that parent the child's stop, when the child is untasked, else the agent's
return, when it has the agent at work ('Fold.agentEndedIn'). An agent
leading no child run, a plain worker or one in a child run, records
nothing: a return would fake its hand-back. Nor does a child run whose
@state next@ hands back now: one over, asking up or awaiting made its
hand-back, or makes it once resumed.
-}
agentEnded ::
    (Shell es) =>
    Steps -> Maybe SessionId -> (RunId -> Bool) -> AgentId -> Eff es Text
agentEnded steps session under agent =
    slotFor session (AgentKey agent) >>= maybe (pure Nothing) ledRun >>= \case
        Nothing -> pure ""
        Just run ->
            onRunLog end run >>= \case
                NoRun -> pure ""
                Ran (Left failure) -> pure (failureText "stop" failure)
                Ran (Right Nothing) -> pure ""
                Ran (Right (Just (parent, role))) -> either (failureText "stop") (const "") <$> onLog (returning run role) parent
  where
    sessioned stamp = Stamp stamp.ts stamp.head session
    noted = Right . (`Plan` (\_ _ -> mempty))
    end stamp run = case run.state.start.principal of
        ByRole parent _ _
            | under parent.run && not (handsBackNow steps stamp run) ->
                fmap
                    (Just (parent.run, (Role.role run.state.start.flow).name) <$)
                    ( record
                        (sessioned stamp)
                        run
                        [Hook (digestOf [runIdText run.state.run, agent.agentIdText, "agent_ended"])]
                        (noted [AgentEnded agent])
                    )
        ByRole {} -> ([], Right Nothing)
        ByUser _ -> ([], Right Nothing)
        ByCaller _ -> ([], Right Nothing)
    returning child role stamp run =
        record
            (sessioned stamp)
            run
            [Hook (digestOf [runIdText run.state.run, agent.agentIdText, "agent_returned"])]
            (noted (maybeToList (Fold.agentEndedIn run.state child role agent)))

{- | The run the slot's agent leads: the one it is bound to, when its own init
bound it there. A worker bound to its spawner's run, or a session from before
the marker, leads none.
-}
ledRun :: (RoFileSystem :> es) => Slot -> Eff es (Maybe RunId)
ledRun slot = do
    bound <- readBinding (bindingFile slot)
    led <- (>>= parseRunId . Text.strip) <$> FileSystem.readText (ledFile slot)
    pure (Monad.mfilter (`elem` led) ((.run) <$> bound))

-- | Whether the run's @state next@ hands it back now, read with no GitHub facts: what it delivers ('handsBack').
handsBackNow :: Steps -> Stamp -> Loaded -> Bool
handsBackNow steps stamp run = handsBack (deliver settled.state.start advice.action)
  where
    (_, settled, _, advice) = settledAdvice steps (Facts Nothing Nothing []) stamp run

{- | The hand-back, then the stop, stashed in a subagent's slot, recorded
where its binding and span are now, each then removed; nothing when none is.
Recorded twice when two hooks replay them at once, each is logged once
('loggedAlready', 'spanEndedSource'), and a stop after its hand-back ends no
span.
-}
replayStash :: (Shell es) => Steps -> HookName -> Slot -> Eff es Text
replayStash steps name slot = do
    bound <- readBinding (bindingFile slot)
    linked <- slotSpan (Just slot)
    let told what file =
            aboutKnown
                (((.run) <$> bound) <|> ((.run) <$> linked))
                ( "state: the "
                    <> what
                    <> " stashed at "
                    <> Text.pack file
                    <> " is no "
                    <> what
                    <> "; removed\n"
                )
    handedBack <- replayFile (stashFile slot) (told "hand-back") $ \event -> case wants steps HandbackHook event of
        Right (Just (Asks want)) -> Just (wantAt steps name (callOf event) want bound linked)
        _ -> Nothing
    stoppedSo <- replayFile (stopFile slot) (told "stop") $ \case
        Hook.AgentStop call _ usage -> Just (maybe (pure "") (endLinked call.session NoHandback usage) linked)
        _ -> Nothing
    pure (handedBack <> stoppedSo)

-- | The hook event stashed in this file, recorded by this act, then removed; one the act takes not is told.
replayFile ::
    (Shell es) =>
    FilePath ->
    (FilePath -> Text) ->
    (Hook.HookEvent -> Maybe (Eff es Text)) ->
    Eff es Text
replayFile file told act =
    FileSystem.readText file >>= \case
        Nothing -> pure ""
        Just stash -> do
            said <- case act
                =<< either (const Nothing) Just (parseHookEvent (LBS.fromStrict (encodeUtf8 stash))) of
                Just recording -> recording
                Nothing -> pure (told file)
            FileSystem.removeFile file
            pure said

-- | What the caller's run says to a want, in the worktree it resolves to; nothing when it has none.
atRun ::
    (Shell es) => Steps -> HookName -> Call -> Want -> Maybe Binding -> Eff es Text
atRun steps name call want bound = do
    worktree <- traverse standing bound
    case resolve (keyOf call.agent) worktree call.cwd of
        Nothing -> pure ""
        Just dir -> FileSystem.inDirectory dir (hookAnswer steps name call bound want)

-- | A key's slot in the session's bindings; none without a session or a store root.
slotFor :: (Environment :> es) => Maybe SessionId -> Key -> Eff es (Maybe Slot)
slotFor session key =
    (\root -> do at <- root; named <- session; slotOf at named key) <$> bindingsRoot

bindingsRoot :: (Environment :> es) => Eff es (Maybe FilePath)
bindingsRoot = storeRoot <$> lookupEnv "XDG_STATE_HOME" <*> lookupEnv "HOME"

-- | A binding file's binding; a file that holds none is no binding.
readBinding :: (RoFileSystem :> es) => FilePath -> Eff es (Maybe Binding)
readBinding path = (>>= bindingIn) <$> FileSystem.readText path

writeBinding :: (WrFileSystem :> es) => FilePath -> Binding -> Eff es ()
writeBinding path binding = writeWhole path (renderBinding binding <> "\n")

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
            Just (Right started)
                | Just start <- Fold.runStart started.event ->
                    either (const Nothing) (Just . Binding started.run start.notes) <$> Git.toplevel
            Just _ -> pure Nothing
            Nothing -> pure Nothing

{- | The worktree's run a spawned worker works for, if one reads: without
one, its brief is the whole of it, as with no run.
-}
workedRun ::
    (Clock :> es, Environment :> es, Git :> es, Log :> es, RoFileSystem :> es) =>
    Eff es (Maybe (OpenGraph, RunState))
workedRun =
    onRun (\_ run -> ([], Right (run.g, run.state))) <&> \case
        Ran (Right found) -> Just found
        Ran (Left _) -> Nothing
        NoRun -> Nothing

-- | The first event of the run the worktree's pointer names, decoded; none without a pointer or a run.
pointedRun ::
    (Git :> es, Log :> es, RoFileSystem :> es) =>
    Eff es (Maybe (Either Log.Unread Envelope))
pointedRun =
    gitDir >>= \case
        Left _ -> pure Nothing
        Right gd ->
            readPointer gd >>= \case
                Nothing -> pure Nothing
                Just run -> Log.firstEvent run

{- | What the worktree's run says to a hook's want, naming it, a disk or git
error too. A log holding a row this state cannot read, as a newer one wrote
it, the hook records nothing in: a spawn or hand-back hook names the
fallbacks (#475), as that record is lost, and the others stay silent (#360).
-}
hookAnswer ::
    (Shell es) => Steps -> HookName -> Call -> Maybe Binding -> Want -> Eff es Text
hookAnswer steps name call bound want =
    pointedRun >>= \case
        Nothing -> pure ""
        Just (Left unread) -> pure (unreadByHook name unread)
        Just (Right started) -> at (Just started.run)
  where
    at found = telling name found (runAnswer steps call bound found want)

-- | A log this state cannot read: the hook records nothing, so a spawn or hand-back is recorded by hand.
unreadByHook :: HookName -> Log.Unread -> Text
unreadByHook name unread = case name of
    SpawnHook -> byHand
    HandbackHook -> byHand
    ResumeHook -> ""
    BindHook -> ""
    RouteHook -> ""
    BeginHook -> ""
    StopHook -> ""
  where
    byHand =
        "state hook "
            <> hookName name
            <> ": the run has an event this state cannot read, "
            <> unreadText unread
            <> ", so the hook records nothing\nfix: with the state that wrote the log, state record <step>.spawned, or pipe the hand-back into state handback <role>\n"

-- | What the run found says to a hook's want, recording what it must; empty when silent, a failure as its text.
runAnswer ::
    (Shell es) =>
    Steps -> Call -> Maybe Binding -> Maybe RunId -> Want -> Eff es Text
runAnswer steps call bound found want = case want of
    -- A hook reads no registered file, so a flow its advice ends re-snapshots none (a known gap).
    ResumeRun opened -> do
        -- Read before the lock, as @state next@ does: GitHub may take its whole timeout.
        (facts, told) <- readFacts
        onHook facts.pr $ \stamp run -> case commit
            stamp
            run
            ( (Cli, SessionStarted (sessionOf call opened))
                : [(Cli, event) | event <- maybeToList (restartOf steps opened.source run.state)]
            ) of
            Left refusal ->
                ( []
                , failureText
                    "resume"
                    (explain run.g (Fold.fuelOf run.state) run.state.at refusal)
                )
            Right (restart, after) ->
                let (new, _, out) = adviceOf steps facts told Nothing stamp after
                 in ( map (.envelope) restart <> new
                    , recordedLines restart <> showRun steps after.g after.state <> out.text
                    )
    SpawnRole spawned spawn -> do
        parent <- callerSpan call
        (facts, told) <- readFacts
        onHook facts.pr $ \stamp run ->
            -- At a choice, the spawn of an action's worker opens a child; elsewhere it records nothing.
            let opening =
                    [ (Cli, event)
                    | Just role <- [spawned]
                    , Just event <- [spawnedAt steps run.state.at role]
                    ]
             in case commit stamp run (opening <> spanStarted run parent spawn) of
                    Left refusal ->
                        ( []
                        , failureText "spawn" (explain run.g (Fold.fuelOf run.state) run.state.at refusal)
                        )
                    Right (written, after) ->
                        let opened = take (length opening) written
                            (new, action, out) = adviceOf steps facts told Nothing stamp after
                            warning = case (action, spawned) of
                                (Advice.Spawn advised _, Just role) -> offAdvice steps after.state.at advised role
                                _ -> Nothing
                            -- A recorded spawn tells its child's budget instead: parallel spawns would each repeat the advice.
                            adviceText = case opened of
                                [] -> out.text
                                _ : _ -> ""
                         in ( map (.envelope) written <> new
                            , (childrenTold after.g (const (printed . recordedLines)) after.state opened).text
                                <> adviceText
                                <> foldMap (<> "\n") warning
                            )
    StartsSpan spawn -> do
        parent <- callerSpan call
        -- A subagent's spawn is no step of the flow, so GitHub is not asked.
        onHook Nothing $ \stamp run -> case commit stamp run (spanStarted run parent (Just spawn)) of
            Left refusal ->
                ( []
                , failureText "spawn" (explain run.g (Fold.fuelOf run.state) run.state.at refusal)
                )
            Right (written, _) -> (map (.envelope) written, "")
    Hook.HandedBack message agent role usage -> do
        linked <- callerSpan call
        runPr >>= \pr -> onHook pr $ \stamp run ->
            let sources = hookSources run.state.run agent role message
                said = either (failureText "handback") (.text)
                -- Its span ends with its hand-back, in one write: a refused hand-back ends none.
                ended =
                    [ (spanEndedSource run.state.run link.spanId, end)
                    | Just link <- [linked]
                    , link.run == run.state.run
                    , Just end <- [Fold.endSpan run.state link.spanId (endingOf message) usage]
                    ]
                told plan =
                    record
                        stamp
                        run
                        (take (length plan.events) sources <> map fst ended)
                        ( Right
                            plan {events = plan.events <> map snd ended, say = childrenTold run.g plan.say}
                        )
             in case ( loggedAlready run.logged sources
                     , followedAt steps run.g run.state role
                     , -- A worker beside the advice returns whatever its report says: one with no token reads as ready.
                       Fold.returnOf run.state role agent.agentId (endingOf message)
                     ) of
                    (True, _, _) -> ([], "")
                    (False, True, _) ->
                        either
                            (\failure -> ([], failureText "handback" failure))
                            (fmap said . told)
                            ( handbackPlan
                                steps
                                stamp.head
                                run.g
                                run.state
                                (nextAsk run)
                                role
                                agent.agentId
                                Nothing
                                message
                            )
                    -- A worker beside the advice returns, its report its spawner's alone: silent.
                    (False, False, back) -> said <$> told (Plan (maybeToList back) (\_ _ -> mempty))
    -- Recorded at its span alone ('wantAt'): no run's flow reads it.
    SpanHandback _ _ -> pure ""
  where
    -- The caller's own span is the parent only in this run: a span names none of another.
    spanStarted run parent spawn =
        [ ( spanStartedSource run.state.run started.toolCall
          , SpanStarted (spanStartOf call.harness parentIn started)
          )
        | Just started <- [spawn]
        ]
      where
        parentIn = case parent of
            Just link | link.run == run.state.run -> Just link.spanId
            _ -> Nothing
    -- A run that is over, bound to another branch or whose PR is merged or closed is
    -- silent too; the hook's session stamps its lines, and its text names the run.
    onHook pr act = do
        branch <- Git.headBranch
        result <- onRun $ \stamp run -> case bound >>= (`staleNote` run.state.run) of
            Just note -> ([], Right note)
            Nothing
                | silent branch ((.readiness) <$> pr) run.logged run.state -> ([], Right "")
                | otherwise ->
                    Right . aboutRun run.state.run
                        <$> act (Stamp stamp.ts stamp.head call.session) run
        pure (either (aboutKnown found . failureText "hook") id (orNoRun result))
    -- GitHub unread is no PR: the hook speaks.
    runPr = fromRight Nothing . pullRequestOf <$> (Gh.prView =<< runShape)

-- | A store that is not this kernel's, or a newer kernel's, is bad input: the user moves or upgrades.
refusalAware ::
    (Error OpenRefusal :> es) =>
    Eff es (Either Failure a) -> Eff es (Either Failure a)
refusalAware act = catchError act (\_ refusal -> pure (Left (refused refusal)))
  where
    refused = \case
        NotAStateStore path found ->
            Failure
                BadInput
                (Text.pack path)
                ( "not a state store ("
                    <> ( case found of
                            ApplicationId app -> "application_id " <> tshow app
                            NotSQLite -> "not an SQLite database"
                       )
                    <> ", expected application_id "
                    <> tshow applicationId
                    <> ")"
                )
                "move the file aside: state makes a fresh store in its place"
        NewerSchema path found known ->
            Failure
                BadInput
                (Text.pack path)
                ( "schema version "
                    <> tshow found
                    <> ", newer than this state ("
                    <> tshow known
                    <> ")"
                )
                "upgrade state"

-- | A disk or process error is the outage exit, never a crash.
outageAware :: Eff es (Either Failure a) -> Eff es (Either Failure a)
outageAware act =
    try act >>= \case
        Right result -> pure result
        Left (e :: IOException) ->
            pure
                ( Left
                    ( Failure
                        Outage
                        "a disk or git failure"
                        (tshow e)
                        "retry once the disk and git work"
                    )
                )

-- | The flows' step table, which the installed @state@ names in @STATE_STEPS@.
loadSteps ::
    (Environment :> es, RoFileSystem :> es) => Eff es (Either Failure Steps)
loadSteps =
    lookupEnv "STATE_STEPS" >>= \case
        Nothing ->
            pure
                ( Left
                    ( Failure
                        Outage
                        "STATE_STEPS is not set"
                        "it names the flows' step table"
                        "run the installed state, which sets it"
                    )
                )
        Just path -> do
            table <- FileSystem.readBytes path
            pure $ case parseSteps (LBS.fromStrict table) of
                Right steps -> Right steps
                Left whys ->
                    Left
                        ( Failure
                            Outage
                            ("the step table " <> Text.pack path)
                            (Text.intercalate "; " whys)
                            "rebuild the installed state"
                        )

execute :: (Shell es) => Steps -> Command -> Eff es (Either Failure Text)
execute steps = \case
    Help -> pure (Right (help steps))
    Render block flow -> pure (Right (rendered steps block flow))
    Init args ->
        inWorktree $ \gd ->
            scopeRuns gd args >>= \case
                True -> execute steps Next
                False -> initRun gd args
    Move target -> inWorktree (`moveRun` target)
    Focus target summary ->
        fmap (.text) . orNoRun
            <$> onRun
                ( \stamp run -> record stamp run (repeat Cli) (unlogged (focusPlan run target summary))
                )
    Tasks -> tasks
    HandOver handover -> handOver handover
    ShowArtifact ref -> showArtifact ref
    MoveGap ref move -> moveGap ref move
    OnRun (Record (NeedDone ref note)) -> closeNeed ref note
    Register location from by -> registerArtifact location from by
    Dump run -> dump run
    Report kind window -> Right <$> Log.report kind window
    Sql statement -> Bifunctor.first sqlRefused <$> Log.sql statement
    Resume run k -> resumePacket run k
    Next -> do
        -- Read before the lock: GitHub may take its whole timeout.
        (facts, told) <- readFacts
        top <- either (const Nothing) Just <$> Git.toplevel
        -- Next reads no registered file: what it decides comes from the fold.
        orNoRun
            <$> handingBack
                steps
                ( \stamp run ->
                    let (new, _, out) = adviceOf steps facts told top stamp run
                     in (eventsOnly new, Right out)
                )
    HandbackOf role child -> do
        input <- Console.readStdin
        case decodeUtf8' input of
            Left _ ->
                pure (Left (Failure BadInput "the hand-back" "stdin is not UTF-8" "state help"))
            Right message -> do
                again <- rereadable
                fmap (.text) . orNoRun
                    <$> appendingOn
                        ( \stamp run ->
                            ending
                                again
                                []
                                stamp
                                run
                                ( unlogged
                                    ( handbackPlan
                                        steps
                                        stamp.head
                                        run.g
                                        run.state
                                        (nextAsk run)
                                        role
                                        Nothing
                                        child
                                        message
                                    )
                                )
                        )
    OnRun command -> do
        -- Read before the lock, as GitHub is: the file the command names, and the run's files.
        file <- traverse readAt (fileOf command)
        unknown <- Monad.filterM unstored (evidenceOf command)
        again <- rereadable
        handingBack
            steps
            ( \stamp run ->
                ending
                    again
                    (readBytes (toList file))
                    stamp
                    run
                    (planOf steps stamp.head file unknown run.g run.state (nextAsk run) command)
            )
            <&> \case
                -- With no run, nothing says where the run is: every event is named.
                NoRun | RecordUnknown name <- command -> Left (anyEvent name)
                NoRun -> Left noRun
                Ran result -> result
  where
    fileOf = \case
        Record recording -> case recording of
            FromFile _ path _ -> Just path
            NamesFile _ path _ -> Just path
            AddsTask path _ -> Just path
            Plain _ -> Nothing
            AtHead _ -> Nothing
            Filing _ -> Nothing
            OnTask _ _ -> Nothing
            OnChild _ _ -> Nothing
            HeadOf _ _ -> Nothing
            OnTasks _ _ -> Nothing
            NeedDone _ _ -> Nothing
        RecordUnknown _ -> Nothing
        Brief _ _ -> Nothing
        ShowRun -> Nothing
        Override _ _ -> Nothing
        Void _ _ -> Nothing
        AskOwn {} -> Nothing
        AskFrom {} -> Nothing
        RuleOn {} -> Nothing
        Retry _ _ -> Nothing
        Forward _ _ -> Nothing
        Answer {} -> Nothing
        Park _ _ -> Nothing
        StopRun _ -> Nothing
        Pending -> Nothing
        NoteOn _ _ -> Nothing
        MoveEpic _ _ -> Nothing

-- | The lines a gap's evidence names: each must be stored, in any run.
evidenceOf :: RunCommand -> [EventRef]
evidenceOf command = [ref | Record (Filing gap) <- [command], OfEvent ref <- gap.evidence]

{- | Whether no run stores the line: no such run, or no line of that seq. A
row this state cannot read is stored all the same.
-}
unstored :: (Log :> es) => EventRef -> Eff es Bool
unstored ref =
    storedLine ref <&> \case
        Left _ -> False
        Right NoSuchRun -> True
        Right NoSuchLine -> True
        Right (StoredLine _) -> False

-- | What a run's line is, looked up by its ref.
data Stored = NoSuchRun | NoSuchLine | StoredLine Envelope

{- | A line of any run as stored, read without the lock and cut at its seq,
so a later line this state cannot read refuses nothing.
-}
storedLine :: (Log :> es) => EventRef -> Eff es (Either Log.Unread Stored)
storedLine ref =
    fmap stored <$> Log.readUntil ref.run (Just (max 1 ref.seq))
  where
    stored logged = case logged.events of
        [] -> NoSuchRun
        events -> maybe NoSuchLine StoredLine (find ((== ref.seq) . (.seq)) events)

{- | @state gap proposed|fixed|wontfix <run:seq>@: the gap's status event,
appended to the gap's own run under its lock, in any state the run is in. A
seq that is no gap, or a gap closed already, is refused there and logged; a
run the store lacks is only told.
-}
moveGap :: (Shell es) => EventRef -> GapMove -> Eff es (Either Failure Text)
moveGap ref move =
    inRunOf
        ref
        (GapMoved ref.seq move)
        (Fold.UnknownGap ref.seq)
        "state resume names the open gaps as <run:seq>"

{- | @state record user_needed <run:seq> --done@: the need's close,
appended to the need's own run as a gap move is ('inRunOf'), when that run
shares the caller's run tree: the same root run ('rootRun'). The caller's
run is the one 'resumedRun' finds. A run outside that tree, the store lacking
it too, is refused before any append, and only told.
-}
closeNeed ::
    (Shell es) => EventRef -> Maybe NonBlank -> Eff es (Either Failure Text)
closeNeed ref note =
    resumedRun >>= \case
        Left failure -> pure (Left failure)
        Right Nothing -> pure (Left noRun)
        Right (Just caller) ->
            ((==) <$> rootRun caller <*> rootRun ref.run) >>= \case
                False -> pure (Left (outsideRunTree ref caller))
                True ->
                    inRunOf
                        ref
                        (UserNeededDone ref.seq note)
                        (Fold.NoOpenNeed ref.seq)
                        "state resume lists what is owed to the user as <run:seq>"

{- | The run a run's tree grows from: its parent's root, else itself. A run
the store lacks, or whose first line this state cannot read, is its own root.
-}
rootRun :: (Log :> es) => RunId -> Eff es RunId
rootRun run =
    Log.firstEvent run >>= \case
        Just (Right first) ->
            maybe
                (pure run)
                rootRun
                (Fold.runStart first.event >>= parentRun . (.principal))
        Just (Left _) -> pure run
        Nothing -> pure run

{- | The event for the line @ref@ names, appended to that line's run under
its lock, whichever run the worktree holds: refused there and logged as
any event is. A run the store lacks is only told, with the code of
@unknown@, what the run would refuse, and @fix@.
-}
inRunOf ::
    (Shell es) =>
    EventRef -> Event -> Fold.Refusal -> Text -> Eff es (Either Failure Text)
inRunOf ref event unknown fix =
    onRunLog
        ( \stamp run ->
            record
                stamp
                run
                (repeat Cli)
                (Right (Plan [event] (const recorded)))
        )
        ref.run
        <&> \case
            NoRun ->
                Left
                    ( Failure
                        BadInput
                        ((refusalCode (FoldRefused unknown)).codeText <> " " <> eventRefText ref)
                        "no such run in the run store"
                        fix
                    )
            Ran result -> (.text) <$> result

readAt :: (RoFileSystem :> es) => FilePath -> Eff es (AbsPath, Contents)
readAt raw = FileSystem.absolute raw >>= \path -> (path,) <$> FileSystem.readContents path

-- | A file read before the lock, or the refusal logged for one that may not be read.
readable :: (AbsPath, Contents) -> Either Unplanned (AbsPath, ByteString)
readable (path, contents) = case contents of
    Readable bytes -> Right (path, bytes)
    Unreadable -> Left (Refusing (FileUnreadable path))

pathText :: AbsPath -> Text
pathText = Text.pack . absPathText

{- | @state artifact <path|url> --kind <k> [--from <seq>] [--span <seq>]@:
the worktree's run registers a file or a URL. A file is read once, before
the lock, and its digest and blob come from those bytes, in the append that
logs it; a file that may not be read logs a refusal.
-}
registerArtifact ::
    (Shell es) =>
    Location FilePath ->
    Maybe Natural ->
    Maybe SpanId ->
    Eff es (Either Failure Text)
registerArtifact location from by = do
    named <- traverse readAt location
    fmap (.text) . orNoRun
        <$> appendingOn
            ( \stamp run ->
                withBlobs
                    (readBytes (toList named))
                    ( record
                        stamp
                        run
                        (repeat Cli)
                        (traverse readable named >>= \found -> unlogged (registerPlan run found from by))
                    )
            )

{- | The artifact a location read gives, derived from the run's artifact of
this seq and made by the agent of this span, if any. A span is any the run
started, open or ended: a lead often registers a report after its hand-back.
-}
registerPlan ::
    Loaded ->
    Location (AbsPath, ByteString) ->
    Maybe Natural ->
    Maybe SpanId ->
    Either Failure Plan
registerPlan run found from by = do
    for_ from derivable
    for_ by spanned
    Right
        ( Plan
            [ArtifactLogged artifact from by]
            ( \_ written ->
                printed
                    ( foldMap
                        ( \(n, logged) ->
                            artifactLine run.state.run n logged
                                <> "show: state artifact show "
                                <> numberedText run.state.run n
                                <> "\n"
                        )
                        (artifactsWritten written)
                    )
            )
        )
  where
    artifact = case found of
        AtUrl kind uri -> Url kind uri
        AtPath kind (path, bytes) -> File (register kind path bytes).file
    derivable n
        | n `elem` map fst (artifactsOf run.logged) = Right ()
        | otherwise =
            Left
                ( Failure
                    BadInput
                    ("--from " <> tshow n)
                    ("line " <> tshow n <> " of run " <> runIdText run.state.run <> " is no artifact")
                    "state artifact <path|url> --kind <k> --from <the seq state artifact printed>"
                )
    spanned span'
        | span' `elem` map fst (spansOf run.logged) = Right ()
        | otherwise =
            Left
                ( Failure
                    BadInput
                    ("--span " <> tshow span'.spanSeq)
                    ( "line "
                        <> tshow span'.spanSeq
                        <> " of run "
                        <> runIdText run.state.run
                        <> " starts no span"
                    )
                    "state artifact <path|url> --kind <k> --span <the seq of the agent's span_started>"
                )

{- | @artifact 7f3a:14 plan sha256:3b9c... 14212 bytes, content stored@, or
@path only@ when its bytes are not kept; a URL's names the URL instead.
-}
artifactLine :: RunId -> Natural -> Artifact -> Text
artifactLine run n artifact =
    "artifact " <> numberedText run n <> " " <> case artifact of
        File file ->
            fileKindText file.kind
                <> " "
                <> digestText file.ref.sha256
                <> " "
                <> tshow file.ref.size.bytes
                <> " bytes, "
                <> (if snapshotted file.kind file.ref.size then "content stored" else "path only")
                <> "\n"
        Url kind uri -> urlKindText kind <> " " <> uriText uri <> "\n"

-- | The artifacts these lines log, each with its seq.
artifactsWritten :: [Written] -> [(Natural, Artifact)]
artifactsWritten written = artifactsOf [w.envelope | w <- written]

{- | The append of these lines and the blobs of the files they register,
from the bytes read before the lock: a refusal registers none.
-}
withBlobs :: [ByteString] -> ([Envelope], a) -> (Appending, a)
withBlobs bytesRead (new, result) =
    (Appending new (blobsOf bytesRead (map snd (artifactsOf new))), result)

{- | What the one re-snapshot step reads before the lock: the files the run
registered, to register again, and the session transcripts it has yet to
register once.
-}
data Reread = Reread
    { files :: [(FileArtifact, Contents)]
    , transcripts :: [(AbsPath, Contents)]
    }

{- | The newest file of each path the worktree's run registered, of a kind
that keeps its bytes, and each 'unregistered' transcript, each read now:
before the lock, as GitHub is. A run that does not load reads none: the
command's own load tells why.
-}
rereadable :: (Shell es) => Eff es Reread
rereadable =
    onRun
        ( \_ run ->
            ( []
            , Right
                ( [ file
                  | (_, file) <- Map.elems (newest (artifactsOf run.logged))
                  , keepsContent file.kind
                  ]
                , unregistered run
                )
            )
        )
        >>= \case
            Ran (Right (files, transcripts)) ->
                Reread
                    <$> traverse (\file -> (file,) <$> FileSystem.readContents file.ref.path) files
                    <*> traverse (\path -> (path,) <$> FileSystem.readContents path) transcripts
            Ran (Left _) -> pure (Reread [] [])
            NoRun -> pure (Reread [] [])

{- | The transcripts the run's sessions name that no artifact of the run
names yet: each is registered once, the first time it is read (S9).
-}
unregistered :: Loaded -> [AbsPath]
unregistered run =
    Set.toList
        ( Set.fromList
            [ path
            | line <- toList run.logged
            , SessionStarted session <- [line.event]
            , Just path <- [session.transcript]
            , Map.notMember path (newest (artifactsOf run.logged))
            ]
        )

{- | The files to register again, from those read before the lock: each whose
bytes changed, derived from the newest artifact of its path, and the paths
that could not be read, skipped; and each transcript read that is still
'unregistered', by path and digest alone. A file registered again since it
was read waits for the next handover or end (#552 ruling 5). A transcript
not yet readable is no skip: it waits for the next one.
-}
resnapshotOf :: Loaded -> Reread -> ([Event], [AbsPath])
resnapshotOf run again =
    ( [ ArtifactLogged
            (File fresh.file)
            (fst <$> Map.lookup fresh.file.ref.path latest)
            Nothing
      | fresh <- snapshots
      ]
        <> [ ArtifactLogged (File (register Transcript path bytes).file) Nothing Nothing
           | (path, Readable bytes) <- again.transcripts
           , path `elem` unregistered run
           ]
    , skipped
    )
  where
    latest = newest (artifactsOf run.logged)
    (snapshots, skipped) =
        resnapshot
            [ (file, contents)
            | (file, contents) <- again.files
            , (snd <$> Map.lookup file.ref.path latest) == Just file
            ]

-- | The bytes of the files read that could be read.
readBytes :: [(a, Contents)] -> [ByteString]
readBytes files = [bytes | (_, Readable bytes) <- files]

{- | 'record' with the blobs of the files it registers, its plan
'resnapshotting' first, from the files read before the lock.
-}
ending ::
    Reread ->
    [ByteString] ->
    Stamp ->
    Loaded ->
    Either Unplanned Plan ->
    (Appending, Either Failure Output)
ending again bytesRead stamp run plan =
    withBlobs
        (bytesRead <> readBytes again.files)
        (record stamp run (repeat Cli) (resnapshotted <$> plan))
  where
    resnapshotted planned =
        let (events, skipped) = resnapshotting stamp again run planned.events
         in Plan events (\after written -> printed skipped <> planned.say after written)

{- | The events a command writes, the run's changed files registered again,
and its sessions' new transcripts registered, ahead of them when they hand the run over or end it, as it leaves its flow
or stops (R8); and the lines naming the files skipped. 'ArtifactLogged'
moves no run, so whether the events end it does not depend on them. Only
the writes an agent asks for run it: @state next@, a hook and 'handedUp'
read no file, so a flow they end re-snapshots none (a known gap).
-}
resnapshotting ::
    Stamp -> Reread -> Loaded -> [Event] -> ([Event], Text)
resnapshotting stamp again run events
    | handsOver || ends =
        let (snapshots, skipped) = resnapshotOf run again
         in (snapshots <> events, foldMap skippedLine skipped)
    | otherwise = (events, "")
  where
    handsOver = not (null [() | HandedOver _ <- events])
    ends = case commit stamp run (map (Cli,) events) of
        Right (_, after) -> not (Fold.over run.state) && Fold.over after.state
        Left _ -> False
    skippedLine path =
        "skipped " <> pathText path <> ": gone or unreadable, its last snapshot kept\n"

{- | @state handover@: the worktree's run handed over to a fresh agent. Each
registered file whose bytes changed is registered again first, in the same
append; one gone or unreadable is skipped and named, and never refuses the
handover (R7).
-}
handOver :: (Shell es) => Handover -> Eff es (Either Failure Text)
handOver handover = do
    again <- rereadable
    fmap (.text) . orNoRun
        <$> appendingOn
            ( \stamp run ->
                let said written =
                        foldMap (uncurry (artifactLine run.state.run)) (artifactsWritten written)
                            <> foldMap
                                (\w -> "handover " <> numberedText run.state.run w.envelope.seq <> "\n")
                                [w | w <- written, HandedOver _ <- [w.envelope.event]]
                            <> "resume with: state resume "
                            <> runIdText run.state.run
                            <> "\n"
                 in ending
                        again
                        []
                        stamp
                        run
                        (Right (Plan [HandedOver handover] (\_ written -> printed (said written))))
            )

{- | @state artifact show <run:seq>@: the stored bytes of a file artifact,
once the store checked they hash to its key, or a URL artifact's URL. A file
whose bytes were not stored exits 3 and a line that is no artifact 4
(#552's Appendix B E). The bytes go out as stored, in no encoding.
-}
showArtifact :: (Shell es) => EventRef -> Eff es (Either Failure Text)
showArtifact ref =
    storedLine ref
        >>= \case
            Left unread -> pure (Left (unreadRefusal ref.run unread))
            Right NoSuchRun -> pure (Left (noArtifact "no such run in the run store"))
            Right NoSuchLine -> pure (Left (noArtifact "the run has no such line"))
            Right (StoredLine line) -> case [artifact | ArtifactLogged artifact _ _ <- [line.event]] of
                [] -> pure (Left (noArtifact ("it is a " <> eventType line.event <> " line")))
                artifact : _ -> case artifact of
                    Url _ uri -> pure (Right (uriText uri <> "\n"))
                    File file ->
                        Log.blob file.ref.sha256 >>= \case
                            Just (Blob bytes) -> Console.outBytes bytes $> Right ""
                            Nothing ->
                                pure
                                    ( Left
                                        ( Failure
                                            NotStored
                                            (pathText file.ref.path)
                                            ( digestText file.ref.sha256
                                                <> ", its bytes not stored: a transcript, or over the cap"
                                            )
                                            ("read the file at " <> pathText file.ref.path)
                                        )
                                    )
  where
    noArtifact why = Failure NotAnArtifact ("artifact " <> eventRefText ref) why "state resume"

{- | @state focus [rK] --summary <line>@: the chief's request in focus
waits, unless it recorded nothing, which is dropped, or it is finished, at
@next@, which a turn back drops and a turn away ends by taking the next
request; the waiting request named takes the focus, else a new one. A turn
back is no new request, so it spends none of the Requests cap. A turn back prints its card, and
the advice from the two logged times, so a replay prints the same.
-}
focusPlan :: Loaded -> Maybe TaskNo -> Maybe OneLine -> Either Failure Plan
focusPlan run target summary = do
    Bifunctor.first refusal (Fold.focusable run.state)
    -- The request in focus waits on nothing: turning to it is no turn.
    for_
        target
        ( \task ->
            if task == run.state.focus
                then Left (refusal (Fold.NotSuspended task))
                else Right ()
        )
    waits <- case (Fold.stage run.g run.state, summary, target) of
        (Fold.Untouched, _, _) -> Right []
        (Fold.Finished, _, Just _) -> Right []
        (Fold.Finished, _, Nothing) -> Right [stepTook NextRequest]
        (Fold.Underway, Just line, _) -> Right [Suspended run.state.focus line]
        (Fold.Underway, Nothing, _) -> Left (refusal (Fold.FocusRecorded run.state.focus))
    before <- cardsOf run
    Right $ Plan (waits <> map Focused (toList target)) $ \after written ->
        let card = target >>= \task -> find ((== task) . (.task)) before
            focusedAt = (.envelope.ts) <$> listToMaybe (reverse written)
         in printed
                . (recordedLines written <>)
                . Text.unlines
                . fromMaybe [focusLine after]
                $ View.cardLines <$> focusedAt <*> card
  where
    refusal = explain run.g (Fold.fuelOf run.state) run.state.at
    focusLine after = taskNoText after.focus <> " in focus at " <> stateNameText (askedAt after)

{- | @state tasks@: the card of each request of the worktree's run, by the
clock, then a line per child run in the store, with how long ago it last
logged an event. Only a child whose agent ended with no hand-back gets
resume advice: the store links no other's agent to its run.
-}
tasks :: (Shell es) => Eff es (Either Failure Text)
tasks = do
    time <- Clock.now
    onRun (\_ run -> ([], (run.state,) <$> cardsOf run)) >>= \case
        NoRun -> pure (Left noRun)
        Ran (Left failure) -> pure (Left failure)
        Ran (Right (state, requests)) -> do
            children <- Log.children state.run
            lines' <- traverse (childLine time state.start) children
            pure
                ( Right
                    ( Text.unlines
                        ( ("notes " <> Text.pack state.start.notes)
                            : concatMap (View.cardLines time) requests <> lines'
                        )
                    )
                )
  where
    childLine time start child =
        either (\failure -> "child " <> runIdText child <> ": " <> failure.why) id
            <$> onLog
                ( \_ run ->
                    ( []
                    , Right
                        (childText start (View.minutesSince time (NonEmpty.last run.logged).ts) run.state)
                    )
                )
                child
    childText start since child =
        let at = stateNameText (askedAt child) <> ", last event " <> since <> " ago"
            line = "child " <> runIdText child.run <> " " <> Codec.flowText child.start.flow
         in case (Fold.over child, child.agentEnded) of
                (True, _) -> line <> " over at " <> at
                (False, Nothing) -> line <> " at " <> at
                (False, Just _) ->
                    line
                        <> " stopped, no hand-back at "
                        <> at
                        <> "\n  "
                        <> deliver
                            start
                            ( Advice.resumeFresh
                                child.run
                                "stopped, no hand-back"
                                (Role.role child.start.flow).name
                                ("from its notes " <> Text.pack child.start.notes)
                            )

-- | The cards of the run's requests, or why its log does not replay.
cardsOf :: Loaded -> Either Failure [Card.Card]
cardsOf run =
    Bifunctor.first
        (explain run.g (Fold.fuelOf run.state) run.state.at)
        (Card.cards <$> Fold.trace run.g run.logged)

{- | @state dump <run>@: the run's rows as stored, one JSON Lines line each in
seq order, read in one statement without the lock. A row of any type or
version prints, so dump never fails on a row.
-}
dump :: (Log :> es) => RunId -> Eff es (Either Failure Text)
dump run =
    Log.rows run <&> \case
        [] -> Left (noSuchRun run)
        lines' -> Right (foldMap (<> "\n") lines')

noSuchRun :: RunId -> Failure
noSuchRun run =
    Failure
        BadInput
        ("run " <> runIdText run)
        "no such run in the run store"
        "state show names the worktree's run"

{- | @state resume [<run>] [--until <seq>]@: the packet a fresh agent takes
the run up from ("State.Cli.Resume"), of the run named, else the run the
session (@STATE_SESSION@) is bound to, else the worktree's. Read in one
statement without the lock, and cut at @--until@ before any line is read: a
line this state cannot read refuses the packet only when the cut keeps it.
Each child run's notes dir is read from its first line alone, so a child's
unreadable line refuses nothing here.
-}
resumePacket ::
    (Shell es) => Maybe RunId -> Maybe Until -> Eff es (Either Failure Text)
resumePacket named k =
    maybe resumedRun (pure . Right . Just) named >>= \case
        Left failure -> pure (Left failure)
        Right Nothing -> pure (Left noRun)
        Right (Just run) ->
            Log.readUntil run ((.seq) <$> k) >>= \case
                Left unread -> pure (Left (unreadRefusal run unread))
                Right Log.Logged {events = []} -> pure (Left (noSuchRun run))
                Right Log.Logged {events = first : rest} -> case replayed run (first :| rest) of
                    Left failure -> pure (Left failure)
                    Right (_, state) ->
                        Right
                            . Resume.packet
                            . Resume.Input state (first :| rest)
                            . Map.fromList
                            . catMaybes
                            <$> traverse
                                notesDirOf
                                [c.child.run | fan <- Map.elems state.fans, c <- fan.children]
  where
    notesDirOf child =
        Log.firstEvent child <&> \case
            Just (Right first) -> (child,) . (.notes) <$> Fold.runStart first.event
            Just (Left _) -> Nothing
            Nothing -> Nothing

-- | The run the session is bound to, else the worktree's run, if any.
resumedRun :: (Shell es) => Eff es (Either Failure (Maybe RunId))
resumedRun =
    stateSession
        >>= (`slotFor` Main)
        >>= slotBinding
        >>= \case
            Just binding -> pure (Right (Just binding.run))
            Nothing -> gitDir >>= traverse readPointer

-- | What a command appends, and what it prints from the state reached and the lines written.
data Plan = Plan {events :: [Event], say :: RunState -> [Written] -> Output}

-- | What a command prints, the hand-back it delivers, and the answer it writes down, if any.
data Output = Output {text :: Text, handback :: Maybe Text, down :: Maybe Down}

instance Semigroup Output where
    Output a first firstDown <> Output b second secondDown = Output (a <> b) (first <|> second) (firstDown <|> secondDown)

instance Monoid Output where
    mempty = Output "" Nothing Nothing

-- | Text that delivers no hand-back.
printed :: Text -> Output
printed text = Output text Nothing Nothing

{- | The answer to the question, written down to the child that asked it, if
one did: the asker read before the answer closed it, the answer after.
-}
writtenDown :: RunState -> RunState -> QId -> Output
writtenDown before after qid = Output "" Nothing (downOf before after qid)

-- | A line per event written, then the command to run next, delivering no hand-back.
recorded :: [Written] -> Output
recorded written = printed (recordedLines written <> nextLine)

{- | An epic's row once it moved, then what comes next: an epic opened
comes before the breakdown that builds on it; one made ready lists its
tasks, as its PR holds their work.
-}
epicMoved :: RunState -> EpicName -> EpicMove -> Text
epicMoved after epic move =
    foldMap
        (\found -> "epic " <> epicRow epic found <> "\n")
        (Map.lookup epic after.epics)
        <> case move of
            Opens _ _ -> "next: state record breakdown.done --tasks <file.json>\n"
            Readies _ -> "tasks on it: " <> onIt <> "\n" <> nextLine
            Merges -> nextLine
  where
    onIt = case [ taskIdText task.id
                | fan <- Map.elems after.fans
                , task <- Fan.tasksOf fan
                , task.base == OnEpic epic
                ] of
        [] -> "none"
        ids -> Text.unwords ids

{- | What a recording prints: a task's head as its row, @task t4 head
<sha>@; any other, a line per event it wrote. Then the command to run next.
-}
recordedAs :: Recording -> [Written] -> Output
recordedAs recording written = case recording of
    HeadOf task sha ->
        printed
            ("task " <> taskIdText task <> " head " <> Codec.shaText sha <> "\n" <> nextLine)
    Plain _ -> recorded written
    AtHead _ -> recorded written
    FromFile {} -> recorded written
    NamesFile {} -> recorded written
    Filing _ -> recorded written
    OnTask _ _ -> recorded written
    OnChild _ _ -> recorded written
    AddsTask _ _ -> recorded written
    OnTasks _ _ -> recorded written
    NeedDone _ _ -> recorded written

-- | What every write that prints no advice of its own says to run next.
nextLine :: Text
nextLine = "next: state next\n"

{- | The file a recording reads, read beforehand, which it registers as an
artifact of its kind, and 'nextAsk', the qid of a question the plan asks.
-}
planOf ::
    Steps ->
    Maybe Sha ->
    Maybe (AbsPath, Contents) ->
    [EventRef] ->
    OpenGraph ->
    RunState ->
    QId ->
    RunCommand ->
    Either Unplanned Plan
planOf steps worktreeHead file unstoredEvidence g state next = \case
    Record recording -> do
        case unstoredEvidence of
            ref : _ -> Left (Refusing (UnknownEvent ref))
            [] -> Right ()
        (registered, unread, text) <- fileRead recording file
        -- The event's seq: the next, after the file's registration.
        let QId _ first = next
        event <-
            unlogged
                ( recordedEvent
                    g
                    state
                    worktreeHead
                    text
                    (first + genericLength registered)
                    recording
                )
        -- The file registered first, then the outcome that names it.
        Right
            ( Plan
                (registered <> [event])
                (\_ written -> printed unread <> recordedAs recording written)
            )
    NoteOn topic text ->
        Right
            ( Plan
                [Noted topic text]
                ( \_ written ->
                    printed
                        ( foldMap
                            (\w -> "note " <> numberedText state.run w.envelope.seq <> " " <> topic <> "\n")
                            written
                            <> nextLine
                        )
                )
            )
    MoveEpic epic move ->
        Right
            (Plan [EpicMoved epic move] (\after _ -> printed (epicMoved after epic move)))
    Override target why -> Right (Plan [Overridden target why] (const recorded))
    Void n why -> Right (Plan [Voided n why] (const recorded))
    AskOwn kind how text -> do
        unlogged (notOpenYet state Itself text)
        (question, events, line) <-
            Bifunctor.first (Told . notSent kind) (ownAsk state next how kind text)
        Right (Plan events (\after _ -> asked question <> delivered after line))
    AskFrom kind from text ->
        unlogged (notOpenYet state from text) >> do
            let question = Question next kind text
            Right
                ( Plan
                    [Asked (Asking question (askedAt state) from)]
                    ( \after _ -> asked question <> delivered after (deliver after.start (Triage question))
                    )
                )
    RecordUnknown name -> Left (Told (unknownEvent g state name))
    RuleOn raw raise proposal ->
        open raw >>= \qid ->
            Right
                ( Plan
                    (raised raise qid <> [RuledOn qid proposal])
                    ( \after _ -> printed ("ruled " <> qidText qid <> "\n") <> writtenDown state after qid
                    )
                )
    Retry task why ->
        unlogged (retryOf state task) <&> \(found, child, stop) ->
            let question =
                    Question
                        next
                        Ask.Stuck
                        ( Ask.flattened
                            ( "retry task "
                                <> taskIdText task
                                <> "? child "
                                <> runIdText child.run
                                <> ": "
                                <> Handback.stopLine stop
                            )
                        )
                ruling =
                    Proposal
                        (Ask.flattened "retry")
                        why
                        (Ask.flattened "another child run on the task")
                        Nothing
             in Plan
                    [ Asked (Asking question (askedAt state) (ChildRun child.run))
                    , RuledOn question.qid ruling
                    ]
                    ( \after _ ->
                        asked question
                            <> printed
                                ( "ruled "
                                    <> qidText question.qid
                                    <> " retry\n\n"
                                    <> taskBrief after (Fold.currentFan after) found
                                )
                    )
    Forward raw raise ->
        open raw >>= \qid -> Right
            . Plan (raised raise qid <> [Forwarded qid (Ask.deliver state.start.principal)])
            $ \after _ ->
                printed ("forwarded " <> qidText qid <> "\n")
                    <> mconcat
                        [ delivered after (deliver after.start (AwaitAnswer p.asking.question))
                        | p <- after.pending
                        , p.asking.question.qid == qid
                        ]
    Answer raw reply by ->
        unlogged (answeredQid state raw) >>= \qid ->
            unlogged (answerEvents state qid reply by) <&> \events ->
                Plan
                    events
                    ( \after _ ->
                        printed ("answered " <> qidText qid <> "\n" <> otherNote after qid)
                            <> writtenDown state after qid
                    )
    Park raw why ->
        open raw >>= \qid ->
            Right
                ( Plan
                    (forwardedFirst state qid <> [QuestionParked qid why])
                    ( \after _ -> printed ("parked " <> qidText qid <> "\n") <> writtenDown state after qid
                    )
                )
    StopRun stop ->
        Right
            ( Plan
                [Event.Stopped stop]
                ( \after _ ->
                    printed "stopped\n"
                        <> delivered after (deliver after.start (Advice.Stopped stop))
                )
            )
    ShowRun -> Right (Plan [] (\_ _ -> printed (showRun steps g state)))
    Pending -> Right (Plan [] (\_ _ -> printed (Text.unlines (pendingLines state))))
    Brief role (Whole task) -> case brief steps g state role task of
        Left unknown ->
            Left
                ( Told
                    ( Failure
                        BadInput
                        ("task " <> taskIdText unknown)
                        "the breakdown has no such task"
                        "state show"
                    )
                )
        Right text -> Right (Plan [] (\_ _ -> printed text))
    Brief role (Section name) -> case briefSection steps role name of
        Left names ->
            Left
                ( Told
                    ( Failure
                        BadInput
                        ("section " <> stateNameText name)
                        (sectionsText names)
                        ("state brief " <> roleText role <> " --section <step>")
                    )
                )
        Right text -> Right (Plan [] (\_ _ -> printed text))
  where
    sectionsText = \case
        [] -> "the role runs no step"
        names ->
            "the role's sections are " <> Text.intercalate ", " (map stateNameText names)
    open = unlogged . openQid state
    asked question = printed ("asked " <> qidText question.qid <> "\n")
    raised raise qid = case raise of
        AsAsked -> []
        ToSecurity -> [RetaggedSecurity qid]
    otherNote after qid =
        Text.unlines
            [ note
            | answer <- after.answers
            , answer.about.qid == qid
            , Just note <- [Ask.otherNote answer.about.kind answer.given]
            ]
    notSent kind refusal =
        Failure
            BadInput
            ("--to user on a " <> kindName kind <> " question")
            (explain g (Fold.fuelOf state) state.at (Fold.NotAllowed refusal)).why
            ( "state ask --kind "
                <> kindName kind
                <> " <question>, without --to: the run answers it"
            )

{- | What a recording takes from the file it names, read before the lock:
the artifact it registers, the line naming a file it may not read, and the
text its event is parsed from. A file the event is parsed from must be read,
or the refusal is logged; one the event only names is registered when it can
be, and refuses nothing.
-}
fileRead ::
    Recording ->
    Maybe (AbsPath, Contents) ->
    Either Unplanned ([Event], Text, Maybe Text)
fileRead recording file = case recording of
    FromFile kind _ _ -> parsedFrom kind
    AddsTask _ _ -> parsedFrom TaskList
    NamesFile kind _ _ -> case file of
        Just (path, Unreadable) ->
            Right
                ( []
                , "file_unreadable "
                    <> pathText path
                    <> ": gone or unreadable, no artifact logged\n"
                , Nothing
                )
        Just (path, Readable bytes) -> Right (registering kind (Just (path, bytes)), "", Nothing)
        Nothing -> Right ([], "", Nothing)
    Plain _ -> Right ([], "", Nothing)
    AtHead _ -> Right ([], "", Nothing)
    Filing _ -> Right ([], "", Nothing)
    OnTask _ _ -> Right ([], "", Nothing)
    OnChild _ _ -> Right ([], "", Nothing)
    HeadOf _ _ -> Right ([], "", Nothing)
    OnTasks _ _ -> Right ([], "", Nothing)
    NeedDone _ _ -> Right ([], "", Nothing)
  where
    parsedFrom kind = do
        found <- traverse readable file
        text <- traverse utf8 found
        Right (registering kind found, "", text)
    utf8 (path, bytes) =
        Bifunctor.first
            ( const
                (Told (Failure BadInput (pathText path) "it is not UTF-8 text" "fix the file"))
            )
            (decodeUtf8' bytes)
    registering kind found =
        [ ArtifactLogged (File (register kind path bytes).file) Nothing Nothing
        | (path, bytes) <- toList found
        ]

-- | The events of an answer: forwarded first if still in triage, so one command takes it from triage to closed.
answerEvents ::
    RunState -> QId -> Ask.Reply -> Maybe Above -> Either Failure [Event]
answerEvents state qid reply by =
    answeredBy state.start.principal qid by <&> \above -> forwardedFirst state qid <> [Answered qid reply above]

{- | Who an answer is from: whoever @--by@ names, else whoever relays it to
the run's agent, the user or the caller. A parent run writes its answer down
itself, so the agent of a run under one gives none: it would close here a
question the parent still holds open.
-}
answeredBy :: Principal -> QId -> Maybe Above -> Either Failure Above
answeredBy principal qid = \case
    Just above -> Right above
    Nothing -> case Ask.deliver principal of
        Ask.TheUser -> Right Ask.TheUser
        Ask.TheCaller -> Right Ask.TheCaller
        ParentRun parent ->
            Left
                ( Failure
                    BadInput
                    ("the answer to " <> qidText qid)
                    ("the parent run " <> runIdText parent <> " answers it")
                    "hand it back as state next prints; the parent's answer comes down to this run"
                )

{- | A question still in triage is forwarded first, to whoever answers it,
before this run answers or parks it. A row that must answer it itself
refuses the forward ('Ask.pass').
-}
forwardedFirst :: RunState -> QId -> [Event]
forwardedFirst state qid = case (.waits) <$> Fold.pendingAt state qid of
    Just ForTriage -> [Forwarded qid (Ask.deliver state.start.principal)]
    Just ForAnswer -> []
    Just (ForLater _) -> []
    Nothing -> []

{- | The event @state record@ appends at seq @n@: the one its recording
names, placed in the scope the run is in.
-}
recordedEvent ::
    OpenGraph ->
    RunState ->
    Maybe Sha ->
    Maybe Text ->
    Natural ->
    Recording ->
    Either Failure Event
recordedEvent g state worktreeHead file n recording =
    Fold.inScope g state <$> namedEvent g state worktreeHead file n recording

{- | The event a recording names, from HEAD or the file it read beforehand;
a gap met at the step the run is at, by the role its flow runs; and from
the run, the breakdown of the task it names: a task unknown to the run is
refused as its event would be.
-}
namedEvent ::
    OpenGraph ->
    RunState ->
    Maybe Sha ->
    Maybe Text ->
    Natural ->
    Recording ->
    Either Failure Event
namedEvent g state worktreeHead file n = \case
    Plain event -> Right event
    Filing gap ->
        Right
            ( Gapped
                ( Gap.filed
                    (GapArea (Ask.flattened (stateNameText (askedAt state))))
                    (Role.role state.start.flow).name
                    gap
                )
            )
    AtHead event -> case worktreeHead of
        Just sha -> Right (event sha)
        Nothing ->
            Left
                ( Failure
                    BadInput
                    "no commit"
                    "the event records HEAD and the worktree has none"
                    "git commit"
                )
    FromFile _ path parse -> parsed path parse
    NamesFile _ _ event -> Right event
    OnTask task event -> onTask task event
    OnChild child event -> Right (event (Fold.childRefIn state child))
    AddsTask path parse -> (\event -> event (Fold.addedTo state n)) <$> parsed path parse
    HeadOf task sha -> onTask task (`TaskHead` sha)
    OnTasks ids event -> event <$> traverse taskRef ids
    -- Never met: the shell appends a need's done in the need's own run first ('closeNeed').
    NeedDone ref note -> Right (UserNeededDone ref.seq note)
  where
    onTask task event = event <$> taskRef task
    taskRef =
        Bifunctor.first (explain g (Fold.fuelOf state) state.at) . Fold.taskRefIn state
    parsed :: FilePath -> (Text -> Either Text a) -> Either Failure a
    parsed path parse = case parse <$> file of
        Just (Right event) -> Right event
        Just (Left why) -> Left (Failure BadInput (Text.pack path) why "fix the file")
        Nothing -> Left (Failure BadInput (Text.pack path) "no such file" "write it first")

{- | A worker's hand-back as the run records it. One with no kind on its
question, or a worker's BLOCKED or FAILED, is the run's to triage.
-}
handbackPlan ::
    Steps ->
    Maybe Sha ->
    OpenGraph ->
    RunState ->
    QId ->
    AgentRole ->
    Maybe AgentId ->
    Maybe RunId ->
    Text ->
    Either Failure Plan
handbackPlan steps worktreeHead g state next role agent child message = do
    parsed <- Bifunctor.first refused (parseHandback message)
    let run = parsed.run <|> child
    typed <-
        Bifunctor.first
            refused
            ( typeHandback
                steps
                g
                state
                worktreeHead
                next
                role
                agent
                message
                parsed {Handback.run = run}
            )
    let from = maybe (roleText role) runIdText run
        triage line =
            "triage: "
                <> oneLineText line
                <> "\nfix: state ask --kind <kind> --from "
                <> from
                <> " <question>\n"
        -- A malformed Gap: line is logged with the defaults, never refused: say how it reads.
        untyped =
            [ "gap logged as "
                <> Gap.gapKindText defaults.kind
                <> " "
                <> Gap.severityText defaults.severity
                <> ", its words not "
                <> Gap.gapLineRule
                <> "\n"
            | defaults <- take 1 [Gap.draft text | Gap.Malformed text <- parsed.gaps]
            ]
    Right
        ( Plan
            typed.events
            ( \_ new ->
                printed
                    (recordedLines new <> foldMap triage typed.untriaged <> Text.concat untyped)
            )
        )
  where
    unread :: Text -> Text -> Failure
    unread fix why = Failure BadInput "the hand-back" why fix
    refused refusal = unread (fixOf refusal) (refusalText refusal)
    fixOf = \case
        NoToken -> again "a token added as line 1"
        NoArea _ -> again ("its Touches: line bare names only, comma-separated: " <> areaNames)
        Why _ -> "state help"
    again what =
        "state handback "
            <> roleText role
            <> foldMap ((" --child " <>) . runIdText) child
            <> " < <the hand-back, "
            <> what
            <> ">"

{- | What @state next@ records and prints, and the advice's action: what GitHub
and the run's Fuel already decide is recorded first, then the advice: its line,
the commands its parent runs ('parentRuns', given the worktree's top when the
command runs in it), the last refusal until the next event, its facts indented, the step's lead and
task text. The advice leads, so a refusal never reads as the next action;
under it, where the run is and each option, one per line.
-}
adviceOf ::
    Steps ->
    Facts ->
    [Text] ->
    Maybe FilePath ->
    Stamp ->
    Loaded ->
    ([Envelope], Action, Output)
adviceOf steps facts told top stamp run = (map (.envelope) new, advice.action, out)
  where
    (new, settled, unsynced, advice) = settledAdvice steps facts stamp run
    out =
        printed (recordedLines new)
            <> delivered settled.state (deliver settled.state.start advice.action)
            <> printed
                ( parentRuns top settled.state.start advice
                    <> foldMap (<> "\n") (deliverMore settled.state.start advice)
                    <> foldMap
                        (\note -> "refused: " <> note.message <> "\nfix: " <> note.fix <> "\n")
                        settled.state.refused
                    <> Text.concat
                        [ "  " <> line <> "\n"
                        | line <-
                            explained settled.state.start advice
                                <> told
                                <> unsynced
                                <> advice.facts
                                <> skippable settled.state
                        ]
                    <> ( if Text.null advice.prompt
                            then ""
                            else "\n" <> deliverPrompt settled.state.start advice <> "\n"
                       )
                )

{- | Under a child's hand-back of its awaited CI, the commands its parent
runs from its own worktree to record the result in the child's run: each
outcome after a @cd@ to the child's worktree, whose top is given when the
command runs in it. The route hook lets a parent's record reach its child's
run (#479).
-}
parentRuns :: Maybe FilePath -> Start -> Advice -> Text
parentRuns top start advice =
    Text.concat
        [ "Parent runs: " <> cdThen at option.command <> "\n"
        | Just at <- [top]
        , ByRole {} <- [start.principal]
        , AwaitOn Ci _ <- [advice.action]
        , option <- advice.leads
        ]

{- | The run once what GitHub and its Fuel already decide is recorded ('due'):
the lines written, the run, what was due but refused (told, not stored), and
the advice there. It reads only the fold: a due outcome that ends the run
re-snapshots no file (a known gap).
-}
settledAdvice ::
    Steps -> Facts -> Stamp -> Loaded -> ([Written], Loaded, [Text], Advice)
settledAdvice steps facts stamp run =
    ( new
    , settled
    , unsynced
    , Advice.heldBy
        settled.state.start
        (Hook.atWork steps settled.state)
        (advise steps settled.g facts settled.state)
    )
  where
    (new, settled, unsynced) = settle run
    settle current = case due facts current.state of
        Nothing -> ([], current, [])
        Just event -> case commit stamp current [(Cli, event)] of
            -- Nobody asked for it, so it is told and not stored.
            Left refusal ->
                ( []
                , current
                ,
                    [ "PR sync refused: "
                        <> (explain current.g (Fold.fuelOf current.state) current.state.at refusal).why
                    ]
                )
            Right (lines', after) -> let (more, final, notes) = settle after in (lines' <> more, final, notes)

-- | A hand-back line under a parent carries the run and its rulings (law Audit), and is delivered.
delivered :: RunState -> Text -> Output
delivered state line
    | handsBack line =
        let handback = Ask.handback line state.run state.rulings
         in Output handback (Just handback) Nothing
    | otherwise = printed (line <> "\n")

{- | What a hook tells of the lines it wrote: a child's spawn or hand-back by
its line and its budget ('Advice.childBudget'), then what the rest say, each
line under @state: @.
-}
childrenTold ::
    OpenGraph ->
    (RunState -> [Written] -> Output) ->
    RunState ->
    [Written] ->
    Output
childrenTold g say state new = printed (foldMap childText children) <> underState (say state others)
  where
    (others, children) =
        partitionEithers
            [ maybe (Left w) (Right . (w,)) (Advice.childBudget g state w.envelope.event)
            | w <- new
            ]
    childText (w, budget) = Text.unlines ("recorded event " <> movedLine w : map ("  " <>) budget)
    underState (Output text handback down) = Output (Text.unlines (map ("state: " <>) (Text.lines text))) handback down

-- | A line per event written, each with where that event left the run.
recordedLines :: [Written] -> Text
recordedLines = foldMap (\w -> "recorded " <> movedLine w <> "\n")

-- | @3 research.spawned -> gather@: the event's number and name, and where it left the run.
movedLine :: Written -> Text
movedLine w =
    tshow w.envelope.seq
        <> " "
        <> eventType w.envelope.event
        <> " -> "
        <> stateNameText w.reached

-- | A line written, and where the run is just after it.
data Written = Written {envelope :: Envelope, reached :: StateName}

-- | The time, commit and session every line written now carries.
data Stamp = Stamp {ts :: UTCTime, head :: Maybe Sha, session :: Maybe SessionId}

{- | The run as replayed under the lock, its log's lines, and its count of
rows, those this command wrote included: a retired row is counted, never
replayed.
-}
data Loaded = Loaded
    { g :: OpenGraph
    , state :: RunState
    , logged :: NonEmpty Envelope
    , rows :: Natural
    }

{- | The lines for these events, each written by its source, in order, and the
run they reach, or the first refusal. An id already logged appends nothing.
-}
commit ::
    Stamp -> Loaded -> [(Source, Event)] -> Either Fold.Refusal ([Written], Loaded)
commit stamp = go []
  where
    go written run = \case
        [] -> Right (reverse written, run)
        (source, event) : rest -> do
            let envelope = stamped stamp source run.state.run (nextSeq run) event
            Fold.appendTo run.g run.state run.logged envelope >>= \case
                Appended next ->
                    go
                        (Written envelope (askedAt next) : written)
                        run {state = next, logged = run.logged <> pure envelope, rows = run.rows + 1}
                        rest
                AlreadyLogged -> go written run rest

-- | The plan written by these sources, or its refusal logged so the next read warns of it.
record ::
    Stamp ->
    Loaded ->
    [Source] ->
    Either Unplanned Plan ->
    ([Envelope], Either Failure Output)
record stamp run sources = \case
    Left (Told failure) -> ([], Left failure)
    Left (Refusing refusal) -> refuse refusal
    Right plan -> case commit stamp run (zip sources plan.events) of
        Right (new, after) -> (map (.envelope) new, Right (plan.say after.state new))
        Left refusal -> refuse (FoldRefused refusal)
  where
    refuse refusal =
        (
            [ stamped
                stamp
                Cli
                run.state.run
                (nextSeq run)
                (Refused (refusedNote g fuel at refusal))
            ]
        , Left (explainRefusal g fuel at refusal)
        )
    g = run.g
    fuel = Fold.fuelOf run.state
    at = run.state.at

{- | Why a command plans no events: a failure it only tells, or a refusal it
also logs as @refused@.
-}
data Unplanned = Told Failure | Refusing CommandRefusal

-- | A failure that logs nothing.
unlogged :: Either Failure a -> Either Unplanned a
unlogged = Bifunctor.first Told

-- | Rows are numbered from 1 in the order written, @started@ first.
nextSeq :: Loaded -> Natural
nextSeq run = run.rows + 1

{- | The qid of a question the next line asks: that line's id, as CloudEvents'
@id@ names its event. A plan puts its question's line first, or counts on
from this. No line of a plan is skipped alone: a plan already logged drops
whole, so its seqs hold.
-}
nextAsk :: Loaded -> QId
nextAsk run = QId run.state.run (nextSeq run)

stamped :: Stamp -> Source -> RunId -> Natural -> Event -> Envelope
stamped stamp source run n event =
    Envelope
        { source
        , seq = n
        , ts = stamp.ts
        , run
        , head = stamp.head
        , session = stamp.session
        , event
        }

{- | 'onRun' for a command that may hand back or answer. A hand-back it
delivers under a parent is recorded in the parent's run too, and an answer
it gives is written down to the child that asked, once this run's lock is
released, as init's spawn is ('spawnedIn').
-}
handingBack ::
    (Shell es) =>
    Steps ->
    (Stamp -> Loaded -> (Appending, Either Failure Output)) ->
    Eff es (Ran Text)
handingBack steps act =
    appendingOn
        ( \stamp run ->
            let (new, result) = act stamp run
             in ( new
                , (\out -> (out.text, upOf run new.events =<< out.handback, out.down)) <$> result
                )
        )
        >>= \case
            NoRun -> pure NoRun
            Ran (Left failure) -> pure (Ran (Left failure))
            Ran (Right (text, up, down)) -> do
                above <- maybe (pure "") (handedUp steps) up
                below <- maybe (pure "") answeredDown down
                pure (Ran (Right (text <> above <> below)))

{- | A child run's hand-back to its parent: the parent, the child's run, its
role, what makes the hand-back one, and the text.
-}
data Up = Up
    { parent :: Parent
    , child :: RunId
    , role :: AgentRole
    , once :: Text
    , text :: Text
    }

{- | A question is handed up once, whatever the child's log grew by since,
as @state next@ delivers it again until its answer comes; any other
hand-back once per line of the child's log, so a CI awaited again after a
resume is news.
-}
upOf :: Loaded -> [Envelope] -> Text -> Maybe Up
upOf run new text = case run.state.start.principal of
    ByUser _ -> Nothing
    -- Its caller holds no run to record the hand-back in: the agent reads it from the reply.
    ByCaller _ -> Nothing
    ByRole parent _ _ ->
        Just (Up parent run.state.run (Role.role run.state.start.flow).name once text)
  where
    once =
        maybe
            (tshow (nextSeq run - 1 + fromIntegral (length new)))
            qidText
            (asks =<< either (const Nothing) (.token) (parseHandback text))
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
The parent's registered files are not read, so a parent this ends
re-snapshots none (a known gap).
-}
handedUp :: (Shell es) => Steps -> Up -> Eff es Text
handedUp steps up =
    try (onLog append up.parent.run) <&> \case
        Right (Right ()) -> ""
        Right (Left failure) -> told (failure.what <> " - " <> failure.why)
        Left (e :: IOException) -> told (tshow e)
  where
    sources = [Hook (digestOf [runIdText up.child, up.once, tshow n]) | n <- [0 :: Int ..]]
    append stamp run
        | loggedAlready run.logged sources = ([], Right ())
        | otherwise = case record stamp run sources (unlogged (planned stamp run)) of
            -- The child tells its refusal; the parent's log does not keep it.
            (_, Left failure) -> ([], Left failure)
            (new, Right _) -> (new, Right ())
    told why =
        "parent: "
            <> why
            <> "\nfix: hand back as printed; the parent's state next catches it\n"
    planned stamp run = case up.parent.link of
        InFan _ ->
            handbackPlan
                steps
                stamp.head
                run.g
                run.state
                (nextAsk run)
                up.role
                Nothing
                (Just up.child)
                up.text
        Direct -> directPlan run.state up.child up.text

-- | A direct child's hand-back as its parent records it: its question, if it asks one.
directPlan :: RunState -> RunId -> Text -> Either Failure Plan
directPlan state child message = do
    typed <-
        Bifunctor.first
            unread
            (typeDirectHandback state child =<< parseHandback message)
    Right (Plan typed.events (\_ new -> recorded new))
  where
    unread refusal = Failure BadInput "the hand-back" (refusalText refusal) "state help"

{- | An answer on its way down: the run that holds it, the child that asked
it of that run, the question and its answer.
-}
data Down = Down {above :: RunId, child :: RunId, qid :: QId, sent :: Sent}

-- | What goes down: the answer, or why the question is parked.
data Sent = Replied Ask.Reply | ParkedFor OneLine

-- | The event that writes it in the child's log, and the command that writes it there by hand.
sentEvent :: Down -> (Event, Text)
sentEvent down = case down.sent of
    Replied reply ->
        ( Answered down.qid reply (ParentRun down.above)
        , "state answer "
            <> qidText down.qid
            <> otherFlag reply
            <> shellWord (Ask.replyWords reply)
            <> " --by "
            <> runIdText down.above
        )
    ParkedFor why ->
        ( QuestionParked down.qid why
        , "state answer " <> qidText down.qid <> " --park " <> shellWord (oneLineText why)
        )
  where
    otherFlag = \case
        Ask.Chose _ -> " "
        Ask.Other _ -> " --other "

{- | The answer the run holds to the question, or why it parked it, for the
child that asked it: the fan-out's live child that asked it, in any of its
hand-backs, else the direct child it came up from. A fan-out's child that
stopped, its stop asked here, is neither.
-}
downOf :: RunState -> RunState -> QId -> Maybe Down
downOf before after qid = do
    asker <-
        ((.child.run) <$> Fan.askerOf fan qid)
            <|> listToMaybe
                [ run
                | open <- maybeToList (Fold.pendingAt before qid)
                , ChildRun run <- [open.asking.from]
                , run `notElem` map (.child.run) fan.children
                ]
    sent <-
        listToMaybe
            [Replied reply | (answered, _, reply) <- Fold.given after, answered == qid]
            <|> (ParkedFor <$> Fold.parkedFor after qid)
    Just (Down after.run asker qid sent)
  where
    fan = Fold.currentFan before

{- | The answer, appended to the asking child's log under its lock by ids
hashed from both runs and the question, so a retry appends it once; then on
down from that child, to the run that asked it first. A refusal or an
outage below does not fail the answer, which tells it with the command that
writes it there by hand: from the child's worktree, which the route hook
lets its parent's answer reach.
-}
answeredDown :: (Shell es) => Down -> Eff es Text
answeredDown down =
    try (onLog write down.child) >>= \case
        Right (Right (before, below)) -> maybe (pure "") answeredDown (downOf before below down.qid)
        Right (Left failure) -> told (failure.what <> " - " <> failure.why) <$> boundTop down.child
        Left (e :: IOException) -> told (tshow e) <$> boundTop down.child
  where
    (event, byHand) = sentEvent down
    -- An answer keeps the ids it always had; a park's add its reason, so a later park or the answer is new.
    source =
        Hook
            ( digestOf
                ([runIdText down.above, qidText down.qid, runIdText down.child] <> parkKey)
            )
    parkKey = case down.sent of
        Replied _ -> []
        ParkedFor why -> ["parked", oneLineText why]
    write stamp run = case commit stamp run [(source, event)] of
        Right (new, after) -> (map (.envelope) new, Right (run.state, after.state))
        -- The answering run tells the refusal; the child's log does not keep it.
        Left refusal -> ([], Left (explain run.g (Fold.fuelOf run.state) run.state.at refusal))
    -- Not the fan's stored worktree: @state move@ leaves it stale.
    told why top =
        "child "
            <> runIdText down.child
            <> ": "
            <> why
            <> "\nfix: "
            <> inWorktreeOf down.child top byHand
            <> "\n"

-- | The worktree's run, locked for one command.
onRun ::
    (Clock :> es, Environment :> es, Git :> es, Log :> es, RoFileSystem :> es) =>
    (Stamp -> Loaded -> ([Envelope], Either Failure a)) -> Eff es (Ran a)
onRun act = appendingOn (\stamp run -> Bifunctor.first eventsOnly (act stamp run))

-- | 'onRun' for a command that appends blobs beside its events.
appendingOn ::
    (Clock :> es, Environment :> es, Git :> es, Log :> es, RoFileSystem :> es) =>
    (Stamp -> Loaded -> (Appending, Either Failure a)) -> Eff es (Ran a)
appendingOn act =
    gitDir >>= \case
        Left failure -> pure (Ran (Left failure))
        Right gd -> readPointer gd >>= maybe (pure NoRun) (appendingLog act)

-- | The run, locked for one command.
onLog ::
    (Clock :> es, Environment :> es, Git :> es, Log :> es) =>
    (Stamp -> Loaded -> ([Envelope], Either Failure a)) ->
    RunId ->
    Eff es (Either Failure a)
onLog act run = orNoRun <$> onRunLog act run

onRunLog ::
    (Clock :> es, Environment :> es, Git :> es, Log :> es) =>
    (Stamp -> Loaded -> ([Envelope], Either Failure a)) -> RunId -> Eff es (Ran a)
onRunLog act = appendingLog (\stamp loaded -> Bifunctor.first eventsOnly (act stamp loaded))

-- | 'onRunLog' for a command that appends blobs beside its events.
appendingLog ::
    (Clock :> es, Environment :> es, Git :> es, Log :> es) =>
    (Stamp -> Loaded -> (Appending, Either Failure a)) -> RunId -> Eff es (Ran a)
appendingLog act run = do
    stamp <- now
    Log.appending run $ \case
        Left unread -> (eventsOnly [], Ran (Left (unreadRefusal run unread)))
        Right logged -> case logged.events of
            [] -> (eventsOnly [], NoRun)
            first : rest -> case replayed run (first :| rest) of
                Left failure -> (eventsOnly [], Ran (Left failure))
                Right (g, state) ->
                    Ran
                        <$> act
                            stamp
                            (Loaded g state {seen = state.seen <> logged.seen} (first :| rest) logged.rows)

-- | A run command's outcome: no run to command, or the command's own.
data Ran a = NoRun | Ran (Either Failure a)

orNoRun :: Ran a -> Either Failure a
orNoRun = \case
    NoRun -> Left noRun
    Ran result -> result

noRun :: Failure
noRun = Failure BadInput "no run in this worktree" "no state init ran here" initFix

{- | A log replayed under the flow its first line starts, with the graph
that replays it, which its appends then walk: the flow's current graph. A log
it refuses tells why.
-}
replayed :: RunId -> NonEmpty Envelope -> Either Failure (OpenGraph, RunState)
replayed run logged@(first :| _) = case Fold.runStart first.event of
    Nothing -> Left (unreplayed run notStarted)
    Just start ->
        let current = graphOf start.flow
         in case replay current logged of
                Right state -> Right (current, state)
                -- Balanced, the Fuel until recorded: only what and why are read.
                Left refusal -> Left (unreplayed run (explain current Balanced Out refusal))

{- | @state init@: idempotent, as a retried brief runs it again: the run
the worktree's pointer names in these notes resumes. A child names its
parent's run, which must exist before this one starts. A worktree holds one
run: init refuses to start one over the unfinished run the pointer names in
another notes dir.

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
    held <- heldHere gd notes
    began <- startOf args
    top <- worktreeTop
    repo <- originRepoHere
    case (,,) <$> held <*> began <*> (topPath =<< top) of
        Left failure -> pure (Left failure)
        Right (resuming, Begin {principal, flow, fuel}, worktree) -> do
            FileSystem.createDirectory notes
            result <- case resuming of
                Just run -> pure (Right ("resumed", run))
                Nothing -> do
                    stamp <- now
                    fresh <- newRunId
                    let start =
                            Start
                                { flow
                                , notes = notes
                                , principal
                                , interface = interfaceOf principal
                                , goal = args.goal
                                , worktree
                                , repo
                                }
                        -- The run starts at its root's Fuel step: a Fuel given takes it at once.
                        begun =
                            Started start : [Took mempty (outcome (LevelSet level)) | level <- toList fuel]
                    Log.locked fresh $ \case
                        Right Log.Logged {rows = 0} -> (zipWith (stamped stamp Cli fresh) [1 ..] begun, Right ("started", fresh))
                        -- Eight random hex digits may meet a run of the same id.
                        _ ->
                            ( []
                            , Left
                                ( Failure
                                    Outage
                                    ("run id " <> runIdText fresh)
                                    "another run in the store has it"
                                    "retry the same state init"
                                )
                            )
            -- The pointer only once the parent took the child: a refused child has no run here.
            accepted <- case (result, principal) of
                (Right said@(_, run), ByRole parent _ _) -> case parent.link of
                    InFan task ->
                        fmap (const said)
                            <$> spawnedIn parent.run run task (absPathText worktree)
                    -- No fan-out to tell: the store's runs.parent links it.
                    Direct -> pure (Right said)
                (Right said, ByUser _) -> pure (Right said)
                (Right said, ByCaller _) -> pure (Right said)
                (Left failure, _) -> pure (Left failure)
            traverse
                (\(verb, run) -> writePointer gd run $> initLines verb run worktree)
                accepted
  where
    notes = shellPathText args.notes
    -- A subagent has no wakes, notifications or background of its own (#351 s4). Hooks
    -- run in it, but a child's hand-back is its own state's to record in the parent.
    interfaceOf = \case
        ByUser _ -> Set.fromList [minBound .. maxBound]
        ByRole {} -> Set.empty
        ByCaller _ -> Set.empty
    initLines verb run worktree =
        Text.unlines
            [ verb <> " " <> runIdText run
            , renderBinding (Binding run notes (absPathText worktree))
            ]
            <> nextLine

{- | Whether the user's init is the flow a scope of the worktree's unfinished
run runs where it is, as when the chief, inside its @engineer@ branch, loads
the engineer's skill: that init prints the run's next step instead, so the
branch stays inline and the session bound to the run. A child's init, or one
naming the run's own flow or a flow no scope there runs, starts as ever.
-}
scopeRuns :: (Shell es) => FilePath -> InitArgs -> Eff es Bool
scopeRuns gd args = case args.origin of
    FromParent _ -> pure False
    FromCaller _ -> pure False
    FromUser _ ->
        maybe False inScope <$> pointed gd
  where
    wanted = fromMaybe defaultFlow args.flow
    inScope state = case liveness state of
        Live ->
            wanted /= state.start.flow
                && Role.flowAt state.start.flow (askedAt state) == wanted
        Ended _ -> False

{- | @state move@: the worktree's run moves to the worktree the directory is
in, as a run started in the wrong worktree must. Its notes stay, so the
parent's and the children's logs still name them; the parent's record of the
child's worktree goes stale, which nothing reads. The target's
pointer is written first and this one removed last: a retry finishes a move
cut short.
-}
moveRun :: (Shell es) => FilePath -> FilePath -> Eff es (Either Failure Text)
moveRun gd target = do
    -- Every read before the first write, the first refusal told.
    here <- readPointer gd
    from <- worktreeTop
    to <- worktreeAt target
    case (,,)
        <$> maybe (Left noRun) Right here
        <*> from
        <*> (traverse topPath =<< elsewhere =<< to) of
        Left failure -> pure (Left failure)
        Right (run, fromTop, (toGd, toTop)) -> do
            there <- pointed toGd
            repo <- FileSystem.inDirectory (absPathText toTop) originRepoHere
            -- The move logged before any pointer moves; one cut short and retried logs it once.
            moving <- case maybe (Right ()) holding (live run =<< there) of
                Left failure -> pure (Left failure)
                Right () ->
                    onLog
                        ( \stamp loaded ->
                            if worktreeOf loaded.state.start loaded.logged == toTop
                                then ([], Right loaded.state.run)
                                else
                                    fmap (const loaded.state.run)
                                        <$> record
                                            stamp
                                            loaded
                                            (repeat Cli)
                                            (Right (Plan [WorktreeMoved toTop repo] (\_ _ -> mempty)))
                        )
                        run
            case moving of
                Left failure -> pure (Left failure)
                Right moved -> do
                    writePointer toGd moved
                    rebind moved fromTop (absPathText toTop)
                    FileSystem.removeFile (pointerOf gd)
                    pure
                        ( Right
                            ("moved " <> runIdText moved <> " to " <> pathText toTop <> "\n" <> nextLine)
                        )
  where
    elsewhere (toGd, toTop)
        | equalFilePath toGd gd =
            Left
                ( Failure
                    BadInput
                    (Text.pack target)
                    "it is this worktree, which holds the run already"
                    "state next"
                )
        | otherwise = Right (toGd, toTop)
    -- A move cut short left the target's pointer naming this run already.
    live run state = case liveness state of
        Live | state.run /= run -> Just state
        Live -> Nothing
        Ended _ -> Nothing
    holding state =
        Left
            ( Failure
                BadInput
                (Text.pack target)
                ( "its worktree holds unfinished run "
                    <> runIdText state.run
                    <> " in "
                    <> Text.pack state.start.notes
                )
                "state stop <reason> <why> there ends it, or state move <another worktree>"
            )

-- | The worktree the run's log last names: the last it moved to, else its start's.
worktreeOf :: Start -> NonEmpty Envelope -> AbsPath
worktreeOf start logged = fst (placeOf start logged)

{- | The worktree's top as the log keeps it. Git names its top absolute and
normalised, so a refusal is git's fault, told as an outage.
-}
topPath :: FilePath -> Either Failure AbsPath
topPath top =
    maybe
        ( Left
            ( Failure
                Outage
                ("git's worktree top " <> Text.pack top)
                "it is not an absolute, normalised path"
                "run state from a worktree git names by its absolute path"
            )
        )
        Right
        (absPath top)

{- | The GitHub repo of the current directory's @origin@, if it names one: a
repo with no @origin@, or another host's, has none.
-}
originRepoHere :: (Git :> es) => Eff es (Maybe Repo)
originRepoHere = either (const Nothing) originRepo <$> Git.originUrl

-- | The git dir and the top of the worktree a directory is in.
worktreeAt ::
    (Git :> es, RoFileSystem :> es) =>
    FilePath -> Eff es (Either Failure (FilePath, FilePath))
worktreeAt dir =
    toplevelAt dir >>= \case
        Nothing -> pure (Left (noWorktree "git finds none there"))
        Just top ->
            fmap (,top) . Bifunctor.first noWorktree
                <$> FileSystem.inDirectory top Git.gitDir
  where
    noWorktree why =
        Failure
            BadInput
            (Text.pack dir <> " is in no git worktree")
            why
            "git worktree add <dir> <branch>, then state move <dir>"

{- | Each binding of the run to the old worktree, in every session, bound to
the new one: hooks route an agent by its binding's worktree.
-}
rebind ::
    (Environment :> es, RoFileSystem :> es, WrFileSystem :> es) =>
    RunId -> FilePath -> FilePath -> Eff es ()
rebind run from to =
    bindingFiles
        >>= traverse_
            ( \file ->
                readBinding file >>= traverse_ (writeBinding file) . (>>= rebound run from to)
            )

{- | The worktree a binding of the run names, in any session: where its
agents work, as 'rebind' moves them with it. None while no agent is bound
to it, as with no hooks.
-}
boundTop ::
    (Environment :> es, RoFileSystem :> es) => RunId -> Eff es (Maybe FilePath)
boundTop run =
    listToMaybe . map (.toplevel) . filter ((== run) . (.run)) . catMaybes
        <$> (traverse readBinding =<< bindingFiles)

-- | Every file of every session in the bindings' store, a binding or not.
bindingFiles :: (Environment :> es, RoFileSystem :> es) => Eff es [FilePath]
bindingFiles = bindingsRoot >>= maybe (pure []) inStore
  where
    inStore root = do
        sessions <- map (root </>) <$> FileSystem.listDirectory root
        concat
            <$> traverse
                (\session -> map (session </>) <$> FileSystem.listDirectory session)
                sessions

-- | The worktree's top, which a child's @spawned@ and init's @run@ line name.
worktreeTop :: (Git :> es) => Eff es (Either Failure FilePath)
worktreeTop =
    Bifunctor.first
        (\why -> Failure BadInput "not inside a git work tree" why "cd <worktree>")
        <$> Git.toplevel

{- | The run init resumes here: the one the worktree's pointer names, if it
keeps these notes and goes on. One that ended leaves the notes to no other
start in this worktree: a 10x's next round gives its engineer a fresh dir.
Refuses a start in these notes while the pointer names an unfinished run in
another: the fix resumes that run or stops it. A run that ended elsewhere,
or that is gone or does not read or replay, holds the worktree no more.
With no unfinished run here, refuses a start in notes an unfinished run
keeps in another worktree, as after @state move@: the fix resumes it there.
-}
heldHere ::
    (Shell es) => FilePath -> FilePath -> Eff es (Either Failure (Maybe RunId))
heldHere gd notes =
    pointed gd >>= \case
        Nothing -> elsewhere
        Just state -> case (equalFilePath state.start.notes notes, liveness state) of
            (True, Live) -> pure (Right (Just state.run))
            (True, Ended why) ->
                pure
                    ( Left
                        ( Failure
                            BadInput
                            ("--notes " <> Text.pack notes)
                            ("its run " <> runIdText state.run <> " " <> why)
                            "state init --notes <a new dir>"
                        )
                    )
            (False, Live) ->
                pure
                    ( Left
                        ( Failure
                            BadInput
                            ("--notes " <> Text.pack notes)
                            ( "the worktree holds unfinished run "
                                <> runIdText state.run
                                <> " in "
                                <> Text.pack state.start.notes
                            )
                            "state next goes on with it, a branch inline in it, or state stop <reason> <why> ends it"
                        )
                    )
            (False, Ended _) -> elsewhere
  where
    elsewhere =
        liveIn notes
            >>= maybe (pure (Right Nothing)) (\run -> Left . heldThere run <$> boundTop run)
    resume = "state init --notes " <> Text.pack notes
    heldThere run top =
        Failure
            BadInput
            ("--notes " <> Text.pack notes)
            ( "unfinished run "
                <> runIdText run
                <> " keeps them in "
                <> maybe "another worktree" Text.pack top
            )
            (inWorktreeOf run top resume)

{- | A command to run in the run's worktree: a @cd@ to the top its binding
names ('boundTop'), else the command with words naming the run.
-}
inWorktreeOf :: RunId -> Maybe FilePath -> Text -> Text
inWorktreeOf run top command =
    maybe
        (command <> ", in run " <> runIdText run <> "'s worktree")
        (`cdThen` command)
        top

-- | The first unfinished run started in these notes, replayed; one gone or that does not read or replay is none.
liveIn :: (Shell es) => FilePath -> Eff es (Maybe RunId)
liveIn notes =
    listToMaybe
        <$> ( Monad.filterM (fmap unfinished . onLog (\_ loaded -> ([], Right loaded.state)))
                =<< Log.inNotes notes
            )
  where
    unfinished = \case
        Right state -> case liveness state of
            Live -> True
            Ended _ -> False
        Left _ -> False

-- | The run the worktree's pointer names, replayed; none without a pointer, or with a run gone or that does not read or replay.
pointed :: (Shell es) => FilePath -> Eff es (Maybe RunState)
pointed gd =
    readPointer gd >>= \case
        Nothing -> pure Nothing
        Just run ->
            either (const Nothing) Just
                <$> onLog (\_ loaded -> ([], Right loaded.state)) run

{- | The child's @spawned@, appended to its parent's log under the parent's
lock, by an id hashed from both runs: a retried init appends it once. Its
task is named beside the parent's breakdown that holds it.
-}
spawnedIn ::
    (Shell es) =>
    RunId -> RunId -> ChildTask TaskId -> FilePath -> Eff es (Either Failure ())
spawnedIn parent child task worktree =
    Monad.void
        <$> onLog
            ( \stamp run ->
                record
                    stamp
                    run
                    [source]
                    ( unlogged
                        ( Bifunctor.bimap
                            (explain run.g (Fold.fuelOf run.state) run.state.at)
                            (\ref -> Plan [Spawned (Child child ref worktree)] (\_ _ -> mempty))
                            (traverse (Fold.taskRefIn run.state) task)
                        )
                    )
            )
            parent
  where
    source = Hook (digestOf [runIdText parent, runIdText child])

-- | Whether a run goes on, or how it ended.
data Liveness = Live | Ended Text

liveness :: RunState -> Liveness
liveness state = case (state.stopped, Fold.over state) of
    (Just stop, _) -> Ended ("stopped: " <> reasonText stop.reason <> " " <> stop.why)
    (Nothing, True) -> Ended "finished"
    (Nothing, False) -> Live

-- | Who starts a run, its flow, and the Fuel given it: a child's task gives one, the 10x's is fixed, a user's other run, the chief's each request too, takes one at its Fuel step.
data Begin = Begin {principal :: Principal, flow :: FlowName, fuel :: Maybe Fuel}

{- | Who starts the run, and its flow: a child runs its task's flow, at its
task's Fuel, the task read from the parent's log.
-}
startOf :: (Shell es) => InitArgs -> Eff es (Either Failure Begin)
startOf args = case args.origin of
    FromUser shape -> pure (Right (atFixedFuel (ByUser shape)))
    FromCaller shape -> pure (Right (atFixedFuel (ByCaller shape)))
    FromParent parent ->
        parentStarts parent >>= \case
            Left failure -> pure (Left failure)
            Right () ->
                onLog (\_ run -> ([], childStart parent args.flow run.g run.state)) parent.run
  where
    atFixedFuel principal =
        let flow = fromMaybe defaultFlow args.flow
         in Begin principal flow (fixedFuel flow)

-- | The parent run must have started.
parentStarts :: (Log :> es) => Parent -> Eff es (Either Failure ())
parentStarts parent =
    Log.exists parent.run <&> \case
        True -> Right ()
        False ->
            Left
                ( Failure
                    BadInput
                    ("--parent " <> runIdText parent.run)
                    "no such run in the run store"
                    initLineFix
                )

{- | The child's principal, its flow and its Fuel. A fan-out's child takes
its task's shape, flow and Fuel. A child with no task, of a parent at the
fork of @route.delegate@, is handed the request whole: its plan is
the parent's, so it runs on past confirm. Else it is a direct child, of a
parent at no fan-out. Either opens its own PR, runs the flow named (else the
default) and settles its own Fuel; a direct child its plan too, as a user's
run does.
-}
childStart ::
    Parent -> Maybe FlowName -> OpenGraph -> RunState -> Either Failure Begin
childStart parent named g state = case parent.link of
    InFan (Tasked taskId) -> do
        task <- childTask g taskId state
        flow <- childFlow named task
        Right (Begin (ByRole parent task.shape task.plan) flow (Just task.fuel))
    InFan Untasked -> taskless
    Direct -> taskless
  where
    -- A child naming no task: the parent's position decides its link.
    taskless = case (Fold.forkingAt g state, Fold.fanAt state.at) of
        (Just _, _) -> untasked (InFan Untasked) ParentDecided
        (Nothing, Just _) ->
            Left
                ( Failure
                    BadInput
                    ("--parent " <> runIdText parent.run)
                    "its run is at a fan-out: a child takes one of its tasks"
                    initLineFix
                )
        (Nothing, Nothing) -> untasked Direct ChildConfirms
    untasked link plan =
        let flow = fromMaybe defaultFlow named
         in Right (Begin (ByRole (Parent parent.run link) OwnPr plan) flow (fixedFuel flow))

{- | The parent's task the child runs: one of the parent's requests, in focus
or waiting, must have it in its breakdown.
-}
childTask :: OpenGraph -> TaskId -> RunState -> Either Failure Task
childTask g taskId state = Bifunctor.bimap notOne (.held) (Fold.taskHolder state taskId)
  where
    notOne requests =
        Failure
            BadInput
            ("--task " <> taskIdText taskId)
            (explain g (Fold.fuelOf state) state.at (Fold.NotOneHolder taskId requests)).why
            initLineFix

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
                    ( "task "
                        <> taskIdText task.id
                        <> " runs the "
                        <> Codec.flowText task.flow
                        <> " flow"
                    )
                    ( "state brief "
                        <> Codec.flowText task.flow
                        <> " --task "
                        <> taskIdText task.id
                        <> ", in the parent's worktree, prints the init line"
                    )
                )

initLineFix :: Text
initLineFix = "state brief engineer, in the parent's worktree, prints the init line"

inWorktree ::
    (Git :> es) =>
    (FilePath -> Eff es (Either Failure a)) -> Eff es (Either Failure a)
inWorktree act = gitDir >>= either (pure . Left) act

now :: (Clock :> es, Environment :> es, Git :> es) => Eff es Stamp
now =
    Stamp
        <$> Clock.now
        <*> Git.headSha
        <*> stateSession

-- | The session @STATE_SESSION@ names, if any.
stateSession :: (Environment :> es) => Eff es (Maybe SessionId)
stateSession = (parseSessionId . Text.pack =<<) <$> lookupEnv "STATE_SESSION"

-- | Short and random: eight hex digits from the kernel's entropy.
newRunId :: (Random :> es) => Eff es RunId
newRunId = do
    bytes <- randomBytes 4
    let hex =
            Text.pack
                ( concatMap
                    (\b -> (if b < 16 then ('0' :) else id) (showHex b ""))
                    (BS.unpack bytes)
                )
    maybe (throwIO (userError "a hex run id did not parse")) pure (parseRunId hex)

{- | A run holding a row this state cannot read, as a newer state wrote it:
every append to it is refused until state is upgraded.
-}
unreadRefusal :: RunId -> Log.Unread -> Failure
unreadRefusal run unread =
    Failure
        BadInput
        ("run " <> runIdText run <> " has an event this state cannot read")
        (unreadText unread)
        "upgrade state"

unreadText :: Log.Unread -> Text
unreadText unread =
    "seq "
        <> tshow unread.seq
        <> ", type "
        <> unread.eventType
        <> " (schema_version "
        <> tshow unread.schemaVersion
        <> ")"

-- | A log whose events read but the flow refuses: written by another kernel, or edited by hand.
unreplayed :: RunId -> Failure -> Failure
unreplayed run refusal =
    Failure
        BadInput
        ("run " <> runIdText run <> " does not replay")
        (refusal.what <> " - " <> refusal.why)
        ( "state dump "
            <> runIdText run
            <> " prints its events; state init --notes <a new dir> starts afresh"
        )

rendered :: Steps -> Block -> FlowName -> Text
rendered steps block flow = case block of
    States -> Render.states g steps
    FuelRows -> Render.fuel (flowSkips flow) g
    Mermaid -> mermaid g
    Kinds -> Render.kinds
    StopRule -> Render.stopRule
    PlanWrong -> Render.planWrong
    InitLine -> case flow of
        EngineerFlow -> initFix <> "\n"
        TenXFlow -> tenXInitFix <> "\n"
        ArchitectFlow -> architectInitFix <> "\n"
        ChiefFlow -> chiefInitFix <> "\n"
  where
    g = graphOf flow

-- | The optional blocks of the flow, with the levels that skip each.
flowSkips :: FlowName -> [(Name, PerFuel SkipWhen)]
flowSkips flowName = case (Role.role flowName).flow of
    SomeFlow flow -> termSkips flow

-- | The worktree's git dir, where the pointer to its run lives.
gitDir :: (Git :> es) => Eff es (Either Failure FilePath)
gitDir =
    Bifunctor.first
        ( \why ->
            Failure
                BadInput
                "not inside a git work tree"
                why
                "cd <worktree>; state keeps one run per worktree"
        )
        <$> Git.gitDir

-- | The worktree's run, if one was started here; a pointer that names no run id is none.
readPointer :: (RoFileSystem :> es) => FilePath -> Eff es (Maybe RunId)
readPointer dir = (>>= parseRunId . Text.strip) <$> FileSystem.readText (pointerOf dir)

writePointer :: (WrFileSystem :> es) => FilePath -> RunId -> Eff es ()
writePointer dir run = FileSystem.writeText (pointerOf dir) (runIdText run <> "\n")

-- | A pointer file in the git dir names the run id, the run's key in the run store.
pointerOf :: FilePath -> FilePath
pointerOf dir = dir </> "state-run"

{- | What the worktree's run does to its PR now, by its start or its
request's target: a round reads its PR by URL. No run, or a log that does
not replay, is a PR of its own, as before rounds.
-}
runShape :: (Shell es) => Eff es Shape
runShape =
    onRun (\_ run -> ([], Right (Fold.shape run.state))) <&> \case
        Ran (Right shape) -> shape
        Ran (Left _) -> OwnPr
        NoRun -> OwnPr

{- | The run's PR on GitHub and the lines it changes, each 'Nothing' when
it cannot be read, with a line saying why, and the children that ended.
-}
readFacts :: (Shell es) => Eff es (Facts, [Text])
readFacts = do
    reply <- Gh.prView =<< runShape
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
    onRun
        (\_ run -> ([], Right (map (.child) (Fan.running (Fold.currentFan run.state)))))
        >>= \case
            NoRun -> pure []
            Ran (Left _) -> pure []
            Ran (Right children) -> concat <$> traverse ended children
  where
    ended child =
        fromRight []
            <$> onLog (\_ run -> ([], Right [child.run | Fold.over run.state])) child.run
