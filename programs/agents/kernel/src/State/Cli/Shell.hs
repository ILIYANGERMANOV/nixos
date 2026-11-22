{- | The effect shell of @state@: read the worktree, git and GitHub, decide
in pure code, then append to the log and print. Every decision is the
kernel's; this module moves data between them and the effects, whose IO
interpreters 'runShellIO' runs.
-}
module State.Cli.Shell (Shell, main, hook, runShellIO, storeDurability, recordedEvent) where

import Control.Applicative ((<|>))
import Control.Exception (IOException)
import Control.Monad qualified as Monad
import Data.Bifunctor qualified as Bifunctor
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Either (fromRight, partitionEithers)
import Data.Foldable (for_, toList, traverse_)
import Data.Functor (($>), (<&>))
import Data.List (find)
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
import Effects.Log (Log, runLogIO)
import Effects.Log qualified as Log
import Effects.Random (Random, randomBytes, runRandomIO)
import Effects.Store (Durability (..))
import Numeric (showHex)
import Numeric.Natural (Natural)
import Options.Applicative qualified as Optparse
import State.Category.Flow (Name)
import State.Category.Fuel (Fuel (Balanced), PerFuel, SkipWhen)
import State.Category.Graph (Node (..), OpenGraph (..), graph, placeName)
import State.Category.Step (StateName, stateNameText)
import State.Cli.Command (
    Block (..),
    BriefPart (..),
    Command (..),
    Exit (..),
    Failure (..),
    InitArgs (..),
    Origin (..),
    Raise (..),
    RunCommand (..),
    Usage (..),
    answeredQid,
    anyEvent,
    architectInitFix,
    chiefInitFix,
    defaultFlow,
    explain,
    failureText,
    help,
    initFix,
    notOpenYet,
    notStarted,
    noteOf,
    openQid,
    optparseText,
    parseCommand,
    parseHook,
    retryOf,
    tenXInitFix,
    unknownEvent,
 )
import State.Cli.Render qualified as Render
import State.Cli.Render.Mermaid (mermaid)
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
    Worktree (..),
    bindingFile,
    bindingIn,
    leadFile,
    ledFile,
    rebound,
    renderBinding,
    resolve,
    sessionDir,
    slotOf,
    slottedAgents,
    staleNote,
    stashFile,
    storeRoot,
 )
import State.Protocol.Handback (
    Handback (..),
    Refusal (..),
    Typed (..),
    areaNames,
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
    Want (..),
    aboutKnown,
    aboutRun,
    callOf,
    delivery,
    encodeReply,
    followedAt,
    hookName,
    hookSources,
    keyOf,
    leadSkill,
    leadSkillName,
    loggedAlready,
    offAdvice,
    parseHookEvent,
    replyOf,
    restartOf,
    silent,
    spawnedAt,
    toldOf,
    wants,
 )
import State.Protocol.Hook qualified as Hook
import State.Protocol.Record (Option (..), Recording (..))
import State.Role (RoleDef (..), SomeFlow (..))
import State.Role qualified as Role
import State.Run.Ask (
    Above (ParentRun),
    ChildTask (..),
    Link (..),
    OneLine,
    Parent (..),
    Principal (..),
    Proposal (..),
    QId,
    Question (..),
    kindName,
    oneLineText,
    qidText,
 )
import State.Run.Ask qualified as Ask
import State.Run.Card qualified as Card
import State.Run.Codec (
    LineError (..),
    LogError (..),
    decodeLine,
    encodeLine,
    eventType,
    reasonText,
    taskIdText,
 )
import State.Run.Codec qualified as Codec
import State.Run.Event (
    AgentRole (..),
    Asker (..),
    Asking (..),
    Child (..),
    DraftPr (..),
    Envelope (..),
    Event (..),
    FlowName (..),
    Note (..),
    RunId,
    SessionId (..),
    Sha,
    Source (..),
    Start (..),
    Task (..),
    TaskId,
    TaskNo,
    Waiting (Ci),
    parseRunId,
    roleText,
    runIdText,
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
    nextQId,
    replay,
 )
import State.Run.Fold qualified as Fold
import State.Run.Id (digestOf)
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

-- | Every effect the shell runs on.
type Shell es =
    ( Clock :> es
    , Console :> es
    , Environment :> es
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
    runEff
        . runClockIO
        . runConsoleIO
        . runEnvironmentIO
        . runFileSystemIO
        . runGhIO
        . runGitIO
        . runLogIO durability
        . runRandomIO

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
                            said <- try (jobReply steps name input (callOf event) job)
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
    Ends end -> replyOf job <$> agentsEnded steps call end

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
    Log.firstLine run >>= \first -> case startedFlow =<< first of
        Just flow | mayDeny flow -> denialAt
        _ -> pure Nothing
  where
    startedFlow line =
        either
            (const Nothing)
            (fmap (.flow) . Fold.runStart . (.event))
            (decodeLine line)
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
    (slot,) <$> maybe (pure Nothing) (readBinding . bindingFile) slot

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
        Just (Right started) -> Fold.runStart started.event >>= principalParent . (.principal)
    principalParent = \case
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
wantAnswer steps name input call want slot bound = case delivery want (keyOf call.agent) slot bound of
    Stash at -> do
        -- Stashed before the binding is read again, as the spawner's hook binds before it
        -- reads the stash: whichever runs second sees the other's file.
        writeWhole (stashFile at) (decodeUtf8Lenient input)
        readBinding (bindingFile at) >>= maybe (pure "") (replayStash steps name at)
    ToRun -> atRun steps name call want bound

-- | A bind: the caller to the run its init printed, or a worker it spawned to the caller's run.
bindAnswer ::
    (Shell es) =>
    Steps -> HookName -> Call -> Bind -> Maybe Slot -> Maybe Binding -> Eff es Text
bindAnswer steps name call bind slot bound = case bind of
    BindSelf binding -> telling name (Just binding.run) ("" <$ traverse_ (bindSelf binding) slot)
    BindChild child role -> do
        -- The spawner's binding as it is: a stale one is told at the worker's hand-back.
        spawner <- boundOrHere call bound
        worktree <- traverse standing spawner
        childSlot <- slotFor call.session (AgentKey child)
        case (worktree, childSlot) of
            (Just (binding, Standing), Just at) -> telling name (Just binding.run) $ do
                writeBinding (bindingFile at) binding
                -- Logged before a stashed hand-back replays, so that hand-back returns it.
                logged <-
                    if Hook.tracked steps role
                        then workerSpawned binding call.session child role
                        else pure ""
                stashed <- replayStash steps name at binding
                pure
                    ( aboutRun
                        binding.run
                        ( "state: "
                            <> roleText role
                            <> " "
                            <> child.agentIdText
                            <> " works in this run\n"
                            <> logged
                        )
                        <> stashed
                    )
            -- A removed worktree's run is done: it takes no worker.
            (Just (_, Removed), _) -> pure ""
            (Nothing, _) -> pure ""
            (_, Nothing) -> pure ""

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

{- | What an agent's stop ends: the stopped agent's child run ('agentEnded'),
and the stopper's children not running on. A stopper waits on its foreground
children, so a child of its run absent from the agents running ended unseen,
as a lead's stop of its child tells nothing at the child. Each is told only
when its log refuses or does not read.
-}
agentsEnded :: (Shell es) => Steps -> Call -> End -> Eff es Text
agentsEnded steps call = \case
    StopsAgent agent -> agentEnded steps call.session (const True) agent
    Stops key running -> do
        own <- case key of
            AgentKey agent -> agentEnded steps call.session (const True) agent
            Main -> pure ""
        stopper <- boundOrHere call . snd =<< callerBinding call
        unseen <- case stopper of
            Nothing -> pure []
            Just binding -> do
                agents <- sessionAgents call.session
                traverse
                    (agentEnded steps call.session (== binding.run))
                    [agent | agent <- agents, agent `notElem` running, AgentKey agent /= key]
        pure (own <> Text.concat unseen)

-- | The subagents with a slot in the session's bindings.
sessionAgents ::
    (Environment :> es, RoFileSystem :> es) => SessionId -> Eff es [AgentId]
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
    (Shell es) => Steps -> SessionId -> (RunId -> Bool) -> AgentId -> Eff es Text
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
    sessioned stamp = Stamp stamp.ts stamp.head (Just session)
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

{- | The worker's spawn, appended to its spawner's log under that run's lock
by an id hashed from the run and the worker, so a bind seen twice appends it
once: the run hands back only once the worker returned. A refusal is told.
-}
workerSpawned ::
    (Shell es) => Binding -> SessionId -> AgentId -> AgentRole -> Eff es Text
workerSpawned binding session child role = either (failureText "bind") (const "") <$> onLog append binding.run
  where
    source = Hook (digestOf [runIdText binding.run, child.agentIdText, "worker_spawned"])
    append stamp run =
        record
            (Stamp stamp.ts stamp.head (Just session))
            run
            [source]
            (Right (Plan [WorkerSpawned role child] (\_ _ -> mempty)))

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
                Right event
                    | Right (Just (Asks want)) <- wants steps HandbackHook event ->
                        atRun steps name (callOf event) want (Just binding)
                _ ->
                    pure
                        ( aboutRun
                            binding.run
                            ( "state: the hand-back stashed at "
                                <> Text.pack (stashFile slot)
                                <> " is no hand-back of a step; removed\n"
                            )
                        )
            FileSystem.removeFile (stashFile slot)
            pure said

-- | What the caller's run says to a want, in the worktree it resolves to; nothing when it has none.
atRun ::
    (Shell es) => Steps -> HookName -> Call -> Want -> Maybe Binding -> Eff es Text
atRun steps name call want bound = do
    worktree <- traverse standing bound
    case resolve (keyOf call.agent) worktree call.cwd of
        Nothing -> pure ""
        Just dir -> FileSystem.inDirectory dir (hookAnswer steps name call bound want)

-- | A key's slot in the session's bindings; none without a store root.
slotFor :: (Environment :> es) => SessionId -> Key -> Eff es (Maybe Slot)
slotFor session key = (>>= \at -> slotOf at session key) <$> bindingsRoot

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
    Eff es (Maybe (Either LineError Envelope))
pointedRun =
    gitDir >>= \case
        Left _ -> pure Nothing
        Right gd ->
            readPointer gd >>= \case
                Nothing -> pure Nothing
                Just run -> fmap decodeLine <$> Log.firstLine run

{- | What the worktree's run says to a hook's want, naming it, a disk or git
error too. A log of another log version, as an older one, the hook records
nothing in: a spawn or hand-back hook names the fallbacks (#475), as that
record is lost, and the others stay silent (#360). One whose first line does
not read names no run but the bound one.
-}
hookAnswer ::
    (Shell es) => Steps -> HookName -> Call -> Maybe Binding -> Want -> Eff es Text
hookAnswer steps name call bound want =
    pointedRun >>= \case
        Nothing -> pure ""
        Just (Left (Unsupported v)) -> pure (unreadByHook name v)
        Just (Left (Malformed _)) -> at ((.run) <$> bound)
        Just (Right started) -> at (Just started.run)
  where
    at found = telling name found (runAnswer steps call bound found want)

-- | A log of another version: the hook records nothing, so a spawn or hand-back is recorded by hand.
unreadByHook :: HookName -> Int -> Text
unreadByHook name v = case name of
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
            <> ": the run's "
            <> versionText v
            <> ", so the hook records nothing\nfix: with the state that wrote the log, state record <step>.spawned, or pipe the hand-back into state handback <role>\n"

-- | What the run found says to a hook's want, recording what it must; empty when silent, a failure as its text.
runAnswer ::
    (Shell es) =>
    Steps -> Call -> Maybe Binding -> Maybe RunId -> Want -> Eff es Text
runAnswer steps call bound found want = case want of
    ResumeRun source -> do
        -- Read before the lock, as @state next@ does: GitHub may take its whole timeout.
        (facts, told) <- readFacts
        onHook facts.pr $ \stamp run -> case commit
            stamp
            run
            [(Cli, event) | event <- maybeToList (restartOf source run.state)] of
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
    SpawnRole spawned -> do
        (facts, told) <- readFacts
        onHook facts.pr $ \stamp run ->
            -- At a choice, the spawn of an action's worker opens a child; elsewhere it records nothing.
            case commit
                stamp
                run
                [ (Cli, event)
                | Just role <- [spawned]
                , Just event <- [spawnedAt steps run.state.at role]
                ] of
                Left refusal ->
                    ( []
                    , failureText "spawn" (explain run.g (Fold.fuelOf run.state) run.state.at refusal)
                    )
                Right (opened, after) ->
                    let (new, action, out) = adviceOf steps facts told Nothing stamp after
                        warning = case (action, spawned) of
                            (Advice.Spawn advised _, Just role) -> offAdvice steps after.state.at advised role
                            _ -> Nothing
                        -- A recorded spawn tells its child's budget instead: parallel spawns would each repeat the advice.
                        adviceText = case opened of
                            [] -> out.text
                            _ : _ -> ""
                     in ( map (.envelope) opened <> new
                        , (childrenTold after.g (const recorded) after.state opened).text
                            <> adviceText
                            <> foldMap (<> "\n") warning
                        )
    Hook.HandedBack message agent role ->
        runPr >>= \pr -> onHook pr $ \stamp run ->
            let sources = hookSources run.state.run agent role message
                said = either (failureText "handback") (.text)
                told =
                    record stamp run sources
                        . fmap (\plan -> plan {say = childrenTold run.g plan.say})
             in case ( loggedAlready run.logged sources
                     , followedAt steps run.g run.state role
                     , Fold.returnOf run.state role agent.agentId
                     ) of
                    (True, _, _) -> ([], "")
                    (False, True, _) ->
                        said
                            <$> told
                                (handbackPlan steps stamp.head run.g run.state role agent.agentId Nothing message)
                    -- A worker spawned beside the advice returns, its report its spawner's alone.
                    (False, False, Just back) -> said <$> told (Right (Plan [back] (\_ _ -> mempty)))
                    (False, False, Nothing) -> ([], "")
  where
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
                        <$> act (Stamp stamp.ts stamp.head (Just call.session)) run
        pure (either (aboutKnown found . failureText "hook") id (orNoRun result))
    -- GitHub unread is no PR: the hook speaks.
    runPr = fromRight Nothing . pullRequestOf <$> (Gh.prView =<< runShape)

-- | A disk or process error is the outage exit, never a crash.
outageAware :: Eff es (Either Failure Text) -> Eff es (Either Failure Text)
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
                (\stamp run -> record stamp run (repeat Cli) (focusPlan run target summary))
    Tasks -> tasks
    Dump run -> dump run
    Next -> do
        -- Read before the lock: GitHub may take its whole timeout.
        (facts, told) <- readFacts
        top <- either (const Nothing) Just <$> Git.toplevel
        orNoRun
            <$> handingBack
                steps
                ( \stamp run ->
                    let (new, _, out) = adviceOf steps facts told top stamp run in (new, Right out)
                )
    HandbackOf role child -> do
        input <- Console.readStdin
        case decodeUtf8' input of
            Left _ ->
                pure (Left (Failure BadInput "the hand-back" "stdin is not UTF-8" "state help"))
            Right message ->
                fmap (.text) . orNoRun
                    <$> onRun
                        ( \stamp run ->
                            record
                                stamp
                                run
                                (repeat Cli)
                                (handbackPlan steps stamp.head run.g run.state role Nothing child message)
                        )
    OnRun command -> do
        -- Read before the lock, as GitHub is.
        file <- traverse FileSystem.readText (fileOf command)
        handingBack
            steps
            ( \stamp run ->
                record
                    stamp
                    run
                    (repeat Cli)
                    (planOf steps stamp.head (Monad.join file) run.g run.state command)
            )
            <&> \case
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

{- | @state dump <run>@: the run's events, one envelope per line in seq
order, read under its lock. A run whose events do not read is named, as
every command names it.
-}
dump :: (Log :> es) => RunId -> Eff es (Either Failure Text)
dump run =
    Log.locked run $ \case
        Left bad -> ([], Left (unreadLine run bad))
        Right [] ->
            ( []
            , Left
                ( Failure
                    BadInput
                    ("run " <> runIdText run)
                    "no such run in the run store"
                    "state show names the worktree's run"
                )
            )
        Right events -> ([], Right (foldMap ((<> "\n") . encodeLine) events))

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

-- | A line per event written, delivering no hand-back.
recorded :: [Written] -> Output
recorded = printed . recordedLines

-- | The file a recording reads, read beforehand: 'Nothing' when it does not exist.
planOf ::
    Steps ->
    Maybe Sha ->
    Maybe Text ->
    OpenGraph ->
    RunState ->
    RunCommand ->
    Either Failure Plan
planOf steps worktreeHead file g state = \case
    Record recording ->
        (\event -> Plan [event] (const recorded))
            <$> recordedEvent g state worktreeHead file recording
    Override target why -> Right (Plan [Overridden target why] (const recorded))
    Void n why -> Right (Plan [Voided n why] (const recorded))
    AskOwn kind how text -> do
        notOpenYet state Itself text
        (question, events, line) <-
            Bifunctor.first (notSent kind) (ownAsk state how kind text)
        Right (Plan events (\after _ -> asked question <> delivered after line))
    AskFrom kind from text ->
        notOpenYet state from text >> do
            let question = Question (nextQId state) kind text
            Right
                ( Plan
                    [Asked (Asking question (askedAt state) from)]
                    ( \after _ -> asked question <> delivered after (deliver after.start (Triage question))
                    )
                )
    RecordUnknown name -> Left (unknownEvent g state name)
    RuleOn raw raise proposal ->
        open raw >>= \qid ->
            Right
                ( Plan
                    (raised raise qid <> [RuledOn qid proposal])
                    ( \after _ -> printed ("ruled " <> qidText qid <> "\n") <> writtenDown state after qid
                    )
                )
    Retry task why ->
        retryOf state task <&> \(found, child, stop) ->
            let question =
                    Question
                        (nextQId state)
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
        answeredQid state raw >>= \qid ->
            answerEvents state qid reply by <&> \events ->
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
                ( Failure
                    BadInput
                    ("task " <> taskIdText unknown)
                    "the breakdown has no such task"
                    "state show"
                )
        Right text -> Right (Plan [] (\_ _ -> printed text))
    Brief role (Section name) -> case briefSection steps role name of
        Left names ->
            Left
                ( Failure
                    BadInput
                    ("section " <> stateNameText name)
                    (sectionsText names)
                    ("state brief " <> roleText role <> " --section <step>")
                )
        Right text -> Right (Plan [] (\_ _ -> printed text))
  where
    sectionsText = \case
        [] -> "the role runs no step"
        names ->
            "the role's sections are " <> Text.intercalate ", " (map stateNameText names)
    open = openQid state
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

{- | The event @state record@ appends: the one its recording names, placed in
the scope the run is in.
-}
recordedEvent ::
    OpenGraph ->
    RunState ->
    Maybe Sha ->
    Maybe Text ->
    Recording ->
    Either Failure Event
recordedEvent g state worktreeHead file recording = Fold.inScope g state <$> namedEvent worktreeHead file recording

-- | The event a recording names, from HEAD or the file it read beforehand.
namedEvent :: Maybe Sha -> Maybe Text -> Recording -> Either Failure Event
namedEvent worktreeHead file = \case
    Plain event -> Right event
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
    FromFile path parse -> case parse <$> file of
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
    AgentRole ->
    Maybe AgentId ->
    Maybe RunId ->
    Text ->
    Either Failure Plan
handbackPlan steps worktreeHead g state role agent child message = do
    parsed <- Bifunctor.first refused (parseHandback message)
    let run = parsed.run <|> child
    typed <-
        Bifunctor.first
            refused
            (typeHandback steps g state worktreeHead role agent parsed {Handback.run = run})
    let from = maybe (roleText role) runIdText run
        triage line =
            "triage: "
                <> oneLineText line
                <> "\nfix: state ask --kind <kind> --from "
                <> from
                <> " <question>\n"
    Right
        ( Plan
            typed.events
            (\_ new -> printed (recordedLines new <> foldMap triage typed.untriaged))
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
        recorded new
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
the advice there.
-}
settledAdvice ::
    Steps -> Facts -> Stamp -> Loaded -> ([Written], Loaded, [Text], Advice)
settledAdvice steps facts stamp run =
    ( new
    , settled
    , unsynced
    , Advice.heldBy
        settled.state.start
        settled.state.workers
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

-- | The run as replayed under the lock, and its log's lines, those this command wrote included.
data Loaded = Loaded {g :: OpenGraph, state :: RunState, logged :: NonEmpty Envelope}

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
                        run {state = next, logged = run.logged <> pure envelope}
                        rest
                AlreadyLogged -> go written run rest

-- | The plan written by these sources, or its refusal logged so the next read warns of it.
record ::
    Stamp ->
    Loaded ->
    [Source] ->
    Either Failure Plan ->
    ([Envelope], Either Failure Output)
record stamp run sources = \case
    Left failure -> ([], Left failure)
    Right plan -> case commit stamp run (zip sources plan.events) of
        Right (new, after) -> (map (.envelope) new, Right (plan.say after.state new))
        Left refusal ->
            let failure = explain run.g (Fold.fuelOf run.state) run.state.at refusal
             in ( [stamped stamp Cli run.state.run (nextSeq run) (Refused (noteOf failure))]
                , Left failure
                )

-- | Lines are numbered from 1 in the order written, @started@ first.
nextSeq :: Loaded -> Natural
nextSeq run = fromIntegral (length run.logged) + 1

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
    (Stamp -> Loaded -> ([Envelope], Either Failure Output)) ->
    Eff es (Ran Text)
handingBack steps act =
    onRun
        ( \stamp run ->
            let (new, result) = act stamp run
             in (new, (\out -> (out.text, upOf run new =<< out.handback, out.down)) <$> result)
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
        | otherwise = case record stamp run sources (planned stamp run) of
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
child that asked it: the fan-out's child waiting on it, else the direct
child it came up from. A fan-out's child that stopped, its stop asked here,
is neither.
-}
downOf :: RunState -> RunState -> QId -> Maybe Down
downOf before after qid = do
    asker <-
        ((.child.run) <$> Fan.askedBy fan qid)
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
onRun act =
    gitDir >>= \case
        Left failure -> pure (Ran (Left failure))
        Right gd -> readPointer gd >>= maybe (pure NoRun) (onRunLog act)

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
onRunLog act run = do
    stamp <- now
    Log.locked run $ \case
        Left bad -> ([], Ran (Left (unreadLine run bad)))
        Right [] -> ([], NoRun)
        Right (first : rest) -> case replayed run (first :| rest) of
            Left failure -> ([], Ran (Left failure))
            Right (g, state) -> Ran <$> act stamp (Loaded g state (first :| rest))

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
    case (,,) <$> held <*> began <*> top of
        Left failure -> pure (Left failure)
        Right (resuming, Begin {principal, flow, fuel}, worktree) -> do
            FileSystem.createDirectory notes
            result <- case resuming of
                Just run -> pure (Right ("resumed", run))
                Nothing -> do
                    stamp <- now
                    fresh <- newRunId
                    let start = Start {flow, notes = notes, principal, interface = interfaceOf principal}
                        -- The run starts at its root's Fuel step: a Fuel given takes it at once.
                        begun =
                            Started start : [Took mempty (outcome (LevelSet level)) | level <- toList fuel]
                    Log.locked fresh $ \case
                        Right [] -> (zipWith (stamped stamp Cli fresh) [1 ..] begun, Right ("started", fresh))
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
                    InFan task -> fmap (const said) <$> spawnedIn parent.run (Child run task worktree)
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
            [verb <> " " <> runIdText run, renderBinding (Binding run notes worktree)]

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
    case (,,) <$> maybe (Left noRun) Right here <*> from <*> (to >>= elsewhere) of
        Left failure -> pure (Left failure)
        Right (run, fromTop, (toGd, toTop)) -> do
            moving <- onLog (\_ loaded -> ([], Right loaded.state.run)) run
            there <- pointed toGd
            case (,) <$> moving <*> maybe (Right ()) holding (live run =<< there) of
                Left failure -> pure (Left failure)
                Right (moved, ()) -> do
                    writePointer toGd moved
                    rebind moved fromTop toTop
                    FileSystem.removeFile (pointerOf gd)
                    pure (Right ("moved " <> runIdText moved <> " to " <> Text.pack toTop <> "\n"))
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
lock, by an id hashed from both runs: a retried init appends it once.
-}
spawnedIn :: (Shell es) => RunId -> Child -> Eff es (Either Failure ())
spawnedIn parent child =
    Monad.void
        <$> onLog
            ( \stamp run -> record stamp run [source] (Right (Plan [Spawned child] (\_ _ -> mempty)))
            )
            parent
  where
    source = Hook (digestOf [runIdText parent, runIdText child.run])

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
        <*> (fmap (SessionId . Text.pack) . nonEmpty <$> lookupEnv "STATE_SESSION")
  where
    nonEmpty = (>>= \s -> if null s then Nothing else Just s)

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

{- | A run whose events do not read, as another kernel's version wrote them:
it is not migrated, and a fresh run in another notes dir holds the worktree
in its place.
-}
unreadLine :: RunId -> LogError -> Failure
unreadLine run bad =
    Failure
        BadInput
        ("run " <> runIdText run <> " event " <> tshow bad.line <> " is not read")
        why
        fix
  where
    why = case bad.why of
        Unsupported v -> versionText v
        Malformed what -> what
    fix = "state init --notes <a new dir> starts afresh"

versionText :: Int -> Text
versionText v = "log version " <> tshow v <> ", this state reads " <> tshow Codec.version

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

-- | Each flow's graph glues, as its test holds: a clash here is a bug.
graphOf :: FlowName -> OpenGraph
graphOf flowName = case (Role.role flowName).flow of
    SomeFlow flow -> either (error . ("the flow does not glue: " <>) . show) id (graph flow)

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
