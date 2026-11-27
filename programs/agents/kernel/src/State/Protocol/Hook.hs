{- | The hooks that keep a run's record as the agents work, without the model
remembering to (#360's hooks contract): the neutral hook event in
(programs/agents/hooks/agent_hook.py), what the run is asked, and the reply out.

@
resume    sessionStart          records session_started, and restarted for a fresh or resumed session; context: show and next
spawn     beforeTool delegate   records span_started; to the lead, context: next, and a warning off the advice
handback  beforeTool handback   records span_ended and a worker's hand-back; context: what it recorded
bind      afterTool shell       binds the agent to the run its @state init@ started or resumed; records session_started once
          afterTool delegate    links a subagent to its span, binds a worker to its spawner's run; records a hand-back or stop it made first
route     beforeTool shell      denies a @state@ command aimed at another run than the agent's
          beforeTool edit,      denies an unbound lead's write: an edit, a commit, a push, a PR
          write, delegate       opened or merged, a spawn
begin     agentStart            context: how a spawned lead begins, or a worker's brief
          promptExpansion       context: how a typed lead skill begins; marks the agent a lead
          beforeTool skill      context: how a called lead skill begins; marks the agent a lead
stop      agentStop             records span_ended with no hand-back, and a child run's agent ended so, its children absent from those running too
          afterTool stopAgent   records the stopped agent's span and child run ended so
@

Each finds the caller's run through its binding ("State.Protocol.Binding"),
and its reply names the run it acted on; @begin@ reads no run, and @stop@
says nothing at an agent's stop, as any context there keeps the agent going.

Only @route@ denies: a @state@ call at another run than the one the agent is
bound to, and a lead's write before its run exists. None rewrites a call:
what a hook says is context, a refusal or an error too (fail open and tell);
auto mode denies a call a hook rewrote. Only the lead steers: a subagent's
spawn or question is ignored, but a hand-back, which only a subagent makes. A child run's hand-back is its own
@state@'s to record in its parent's run, so the hook leaves it be.
-}
module State.Protocol.Hook (
    HookName (..),
    hookName,
    hookPurpose,
    HookEvent (..),
    Call (..),
    callOf,
    ToolCallId (..),
    Spawn (..),
    Agent (..),
    Tool (..),
    StartSource (..),
    Opened (..),
    sessionOf,
    initSession,
    parseHookEvent,
    Job (..),
    Want (..),
    Bind (..),
    Begin (..),
    End (..),
    LeadSkill (..),
    leadSkill,
    leadSkillName,
    Gate (..),
    wants,
    keyOf,
    Delivery (..),
    delivery,
    aboutRun,
    aboutKnown,
    silent,
    offAdvice,
    followedAt,
    beside,
    tracked,
    atWork,
    spawnedAt,
    opensChild,
    hookSources,
    spanStartedSource,
    spanEndedSource,
    spanOfCall,
    spanStartOf,
    trackedRole,
    restartOf,
    loggedAlready,
    Reply (..),
    replyOf,
    toldOf,
    encodeReply,
) where

import Control.Monad (guard)
import Data.Aeson (
    Object,
    Value (..),
    eitherDecode,
    encode,
    object,
    withObject,
    (.:),
    (.=),
 )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString.Lazy qualified as LBS
import Data.List (find)
import Data.List.NonEmpty (NonEmpty, toList)
import Data.Maybe (isJust, listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import State.Artifact (AbsPath, absPath)
import State.Category.Flow (ScopePath)
import State.Category.Graph (Metered (..), Node (..), OpenGraph, Place (..))
import State.Category.Step (Sing, SomeOutcome (..), SomeStep (..), stepName)
import State.Protocol.Advice (Readiness (..))
import State.Protocol.Binding (
    AgentId (..),
    Binding (..),
    Key (..),
    Slot,
    SpanLink,
    bindingIn,
 )
import State.Role (leads)
import State.Run.Codec (usageOf)
import State.Run.Event (
    AgentRole (..),
    Branch,
    DraftPr (..),
    Envelope (..),
    Event (Restarted, SessionStarted, Took),
    Harness,
    RunId,
    Session (..),
    SessionId,
    Source (..),
    SpanId (..),
    SpanStart (..),
    Usage (..),
    parseHarness,
    parseSessionId,
    roleText,
    runIdText,
    tookIn,
    unreported,
 )
import State.Run.Fan (Fan (..))
import State.Run.Fold (
    Open (..),
    RunState (..),
    Worker (..),
    forks,
    ledger,
    over,
    unvoided,
 )
import State.Run.Id (digestOf)
import State.Step.Build (Outcome (DraftDone))
import State.Step.Build qualified as Build
import State.Step.Catalog (AnyOutcome (..), AnyStep (..), Layer (..))
import State.Step.Gather qualified as Gather
import State.Table (Steps, agentRoles, stepsRunBy)
import System.FilePath ((</>))

data HookName
    = ResumeHook
    | SpawnHook
    | HandbackHook
    | BindHook
    | RouteHook
    | BeginHook
    | StopHook
    deriving stock (Eq, Show, Enum, Bounded)

-- | As @kernel/hooks.nix@ names them on the command line.
hookName :: HookName -> Text
hookName = \case
    ResumeHook -> "resume"
    SpawnHook -> "spawn"
    HandbackHook -> "handback"
    BindHook -> "bind"
    RouteHook -> "route"
    BeginHook -> "begin"
    StopHook -> "stop"

-- | What the hook does, as @state-hook --help@ lists it.
hookPurpose :: HookName -> Text
hookPurpose = \case
    ResumeHook -> "At session start: prints the run and its next action"
    SpawnHook -> "Before a delegate: next, and a warning off the advice"
    HandbackHook -> "Before a hand-back: records it, printing the record"
    BindHook -> "After a shell or delegate: binds the agent to its run"
    RouteHook -> "Denies a state call off its run, a write before init"
    BeginHook -> "At a spawn or a lead skill: how its work begins"
    StopHook -> "At an agent's stop: records a child run's agent ended"

{- | One event of the neutral contract. @history@ and @context@ are required,
never read. A tool's call carries the harness's id of it, when it gives one; a
hand-back and a stop the tokens the agent's own requests used.
-}
data HookEvent
    = SessionStart Call Opened
    | -- | The tool's call, its input, and the tokens of a hand-back ('unreported' for any other tool).
      BeforeTool Call Tool (Maybe ToolCallId) Object Usage
    | -- | The tool's call, its input, and its output as the client gave it.
      AfterTool Call Tool (Maybe ToolCallId) Object Value
    | -- | A subagent starts, before its first turn.
      AgentStart Call
    | -- | A typed @/name@ expanded to its skill or command, by that name.
      PromptExpansion Call Text
    | {- | The caller stops, and the agents still running in its session: its
      own id is among them when it is a subagent, so it is never read for it.
      The tokens its own requests used last.
      -}
      AgentStop Call [AgentId] Usage
    deriving stock (Eq, Show)

{- | A hook's caller; a hook naming an empty session names none. The harness
running the session, and the session's transcript when it names one.
-}
data Call = Call
    { session :: Maybe SessionId
    , cwd :: FilePath
    , agent :: Maybe Agent
    , harness :: Harness
    , transcript :: Maybe AbsPath
    }
    deriving stock (Eq, Show)

callOf :: HookEvent -> Call
callOf = \case
    SessionStart call _ -> call
    BeforeTool call _ _ _ _ -> call
    AfterTool call _ _ _ _ -> call
    AgentStart call -> call
    PromptExpansion call _ -> call
    AgentStop call _ _ -> call

{- | The harness's id of one tool call (OpenTelemetry's
@gen_ai.tool.call.id@): a spawn's before and after events share it.
-}
newtype ToolCallId = ToolCallId Text
    deriving stock (Eq, Show)

-- | The subagent making the call; the lead is none. Either field is absent when its agent gives none.
data Agent = Agent {agentId :: Maybe AgentId, role :: Maybe AgentRole}
    deriving stock (Eq, Show)

-- | @vocabulary.json@'s tools, in its order.
data Tool
    = Shell
    | Read
    | Edit
    | Write
    | Delegate
    | HandbackTool
    | Web
    | Skill
    | StopAgent
    | Other
    deriving stock (Eq, Show, Enum, Bounded)

-- | Why a session started: @vocabulary.json@'s sources, in its order.
data StartSource = Startup | Resumed | Compact
    deriving stock (Eq, Show, Enum, Bounded)

-- | What a session start tells beside its caller: why it started, and the model it asked for.
data Opened = Opened {source :: StartSource, model :: Maybe Text}
    deriving stock (Eq, Show)

-- | The session as its run keeps it ('SessionStarted').
sessionOf :: Call -> Opened -> Session
sessionOf call opened =
    Session
        { harness = call.harness
        , transcript = call.transcript
        , trigger = startSourceName opened.source
        , model = opened.model
        }

{- | The session a bind by @state init@ starts on its run: the caller's, by
its own facts, unless the caller names no session or the run logs its start
already. A run made mid-session, which no session start found, so has one.
-}
initSession :: (Foldable t) => Call -> t Envelope -> Maybe Session
initSession call logged = case call.session of
    Just session
        | not (any (startOf session) logged) ->
            Just
                Session
                    { harness = call.harness
                    , transcript = call.transcript
                    , trigger = "init"
                    , model = Nothing
                    }
    _ -> Nothing
  where
    startOf session envelope = case envelope.event of
        SessionStarted _ -> envelope.session == Just session
        _ -> False

-- | The event on stdin; an unknown event, tool or source is an error, as in @agent_hook.py@.
parseHookEvent :: LBS.ByteString -> Either Text HookEvent
parseHookEvent input = either (Left . Text.pack) Right $ do
    value <- eitherDecode input
    flip parseEither value $ withObject "hook event" $ \o -> do
        call <-
            Call . parseSessionId
                <$> o .: "session"
                <*> o .: "cwd"
                <*> (o .: "agent" >>= agentOf)
                <*> (o .: "harness" >>= harnessOf)
                <*> (o .: "transcript_path" >>= traverse transcriptPath)
        (o .: "event" :: Parser Text) >>= \case
            "sessionStart" ->
                SessionStart call
                    <$> ( Opened
                            <$> (o .: "source" >>= named "source" startSourceName)
                            <*> o .: "request_model"
                        )
            "beforeTool" -> do
                _ <- o .: "history" :: Parser [Text]
                BeforeTool call
                    <$> tool o
                    <*> toolCall o
                    <*> o .: "input"
                    <*> usage o
            "afterTool" -> do
                _ <- o .: "context" :: Parser Value
                AfterTool call <$> tool o <*> toolCall o <*> o .: "input" <*> o .: "output"
            "agentStart" -> pure (AgentStart call)
            "promptExpansion" -> PromptExpansion call <$> o .: "skill"
            "agentStop" ->
                AgentStop call . map AgentId
                    <$> o .: "running"
                    <*> usage o
            other ->
                fail
                    ( "no event "
                        <> Text.unpack other
                        <> ": sessionStart, beforeTool, afterTool, agentStart, promptExpansion or agentStop"
                    )
  where
    tool o = o .: "tool" >>= named "tool" toolName
    toolCall o = fmap ToolCallId <$> o .: "call"
    -- A usage left out, or a count left out of it, is not reported, never 0.
    usage o = o .: "usage" >>= maybe (pure unreported) (withObject "usage" usageOf)
    agentOf = \case
        Null -> pure Nothing
        value ->
            withObject
                "agent"
                ( \a ->
                    Just
                        <$> (Agent . fmap AgentId <$> a .: "id" <*> (fmap AgentRole <$> a .: "role"))
                )
                value
    harnessOf raw = maybe (fail "no harness: empty") pure (parseHarness raw)
    -- Not absolute is no transcript the contract allows: refused, as an unknown source is.
    transcriptPath raw =
        maybe
            (fail ("no absolute normalised transcript_path " <> raw))
            pure
            (absPath raw)
    named :: (Enum a, Bounded a) => String -> (a -> Text) -> Text -> Parser a
    named what name raw =
        maybe
            (fail ("no " <> what <> " " <> Text.unpack raw))
            pure
            (lookup raw [(name x, x) | x <- [minBound .. maxBound]])

toolName :: Tool -> Text
toolName = \case
    Shell -> "shell"
    Read -> "read"
    Edit -> "edit"
    Write -> "write"
    Delegate -> "delegate"
    HandbackTool -> "handback"
    Web -> "web"
    Skill -> "skill"
    StopAgent -> "stopAgent"
    Other -> "other"

startSourceName :: StartSource -> Text
startSourceName = \case
    Startup -> "startup"
    Resumed -> "resume"
    Compact -> "compact"

{- | What a hook does: ask the caller's run, bind an agent to its run, route
a call to the agent's run, or tell how work begins.
-}
data Job = Asks Want | Binds Bind | Routes Gate | Begins Begin | Ends End
    deriving stock (Eq, Show)

{- | A call @route@ weighs: a shell command (its text), or a write no run may
miss. An edit or write carries its file, joined to the caller's directory
when relative; 'Nothing' when its input names none.
-}
data Gate
    = RunsShell Text
    | Edits (Maybe FilePath)
    | Writes (Maybe FilePath)
    | Spawns
    deriving stock (Eq, Show)

-- | What a hook asks of the worktree's run.
data Want
    = -- | Why the session started.
      ResumeRun Opened
    | -- | The role the lead spawns, when its input names one, and the span it starts, when its call makes one.
      SpawnRole (Maybe AgentRole) (Maybe Spawn)
    | -- | A subagent's spawn: only the span it starts.
      StartsSpan Spawn
    | {- | A step runner's hand-back ('trackedRole'): its message, who sent it,
      its role, and the tokens its own requests used.
      -}
      HandedBack Text Agent AgentRole Usage
    | -- | Any other subagent's hand-back, its message and tokens: only its span ends.
      SpanHandback Text Usage
    deriving stock (Eq, Show)

{- | A subagent spawned, as its spawn call names it: the call, its role, its
brief in full, and the model it asks for, if any.
-}
data Spawn = Spawn
    { toolCall :: ToolCallId
    , role :: AgentRole
    , brief :: Text
    , model :: Maybe Text
    }
    deriving stock (Eq, Show)

data Bind
    = -- | The caller to the run its @state init@ printed.
      BindSelf Binding
    | {- | A subagent the caller spawned, by its agent id: linked to the span
      its spawn call started, and, a flow role's worker, by its role, bound to
      the caller's run.
      -}
      BindSpawned AgentId (Maybe ToolCallId) (Maybe AgentRole)
    deriving stock (Eq, Show)

-- | Whose work begins, and where its text goes.
data Begin
    = -- | A spawned lead (an engineer, a 10x), which leads a run of its own.
      SpawnedLead
    | -- | A spawned step runner.
      SpawnedWorker AgentRole
    | -- | A lead skill typed as @/name@: context beside the prompt.
      TypedSkill LeadSkill
    | -- | A lead skill the agent called: context beside the call.
      CalledSkill LeadSkill
    deriving stock (Eq, Show)

{- | What ends with an agent: its span, and the child run it leads, if it
handed nothing back ("State.Cli.Shell"'s @agentEnded@).
-}
data End
    = {- | The caller stopped, by its key (the lead's is 'Main'), and the agents
      still running: its children absent from them ended too. The tokens its
      own requests used.
      -}
      Stops Key [AgentId] Usage
    | -- | The caller stopped this agent.
      StopsAgent AgentId
    deriving stock (Eq, Show)

{- | What the hook asks of the run, 'Nothing' when it has nothing to do: a
subagent's spawn or question, or a hand-back the run does not follow (a
reviewer's goes to its review-lead). A hook at an event it is not declared on
is an error.
-}
wants :: Steps -> HookName -> HookEvent -> Either Text (Maybe Job)
wants steps hook event = case hook of
    ResumeHook -> case event of
        SessionStart call opened -> Right (lead call (ResumeRun opened))
        BeforeTool {} -> undeclared
        AfterTool {} -> undeclared
        AgentStart _ -> undeclared
        PromptExpansion _ _ -> undeclared
        AgentStop {} -> undeclared
    -- Every spawn in a run starts a span; only the lead's is a step of its flow.
    SpawnHook -> case event of
        BeforeTool call _ toolCall input _ ->
            Right $ case lead call (SpawnRole role spawn) of
                Just job -> Just job
                Nothing -> Asks . StartsSpan <$> spawn
          where
            role = AgentRole <$> textAt "subagent_type" input
            spawn =
                Spawn
                    <$> toolCall
                    <*> role
                    <*> textAt "prompt" input
                    <*> pure (textAt "model" input)
        SessionStart {} -> undeclared
        AfterTool {} -> undeclared
        AgentStart _ -> undeclared
        PromptExpansion _ _ -> undeclared
        AgentStop {} -> undeclared
    -- Every subagent's hand-back ends its span; a step runner's is also its run's ('trackedRole').
    HandbackHook -> case event of
        BeforeTool call _ _ input usage -> Right $ case (call.agent, textAt "message" input) of
            (Just agent, Just message) -> Just . Asks $ case trackedRole steps agent of
                Just role -> HandedBack message agent role usage
                Nothing -> SpanHandback message usage
            _ -> Nothing
        SessionStart {} -> undeclared
        AfterTool {} -> undeclared
        AgentStart _ -> undeclared
        PromptExpansion _ _ -> undeclared
        AgentStop {} -> undeclared
    BindHook -> case event of
        AfterTool _ tool toolCall input output -> Right (Binds <$> bindOf steps tool toolCall input output)
        SessionStart {} -> undeclared
        BeforeTool {} -> undeclared
        AgentStart _ -> undeclared
        PromptExpansion _ _ -> undeclared
        AgentStop {} -> undeclared
    RouteHook -> case event of
        BeforeTool call tool _ input _ ->
            Right $
                Routes <$> case tool of
                    Shell -> RunsShell <$> textAt "command" input
                    Edit -> Just (Edits (fileOf call input))
                    Write -> Just (Writes (fileOf call input))
                    Delegate -> Just Spawns
                    Read -> Nothing
                    HandbackTool -> Nothing
                    Web -> Nothing
                    Skill -> Nothing
                    StopAgent -> Nothing
                    Other -> Nothing
        SessionStart {} -> undeclared
        AfterTool {} -> undeclared
        AgentStart _ -> undeclared
        PromptExpansion _ _ -> undeclared
        AgentStop {} -> undeclared
    BeginHook -> case event of
        AgentStart call -> Right (Begins <$> (spawnedBegin steps =<< (.role) =<< call.agent))
        PromptExpansion _ skill -> Right (Begins . TypedSkill <$> leadSkill skill)
        BeforeTool _ tool _ input _ ->
            Right
                ( Begins . CalledSkill
                    <$> (guard (tool == Skill) *> textAt "skill" input >>= leadSkill)
                )
        SessionStart {} -> undeclared
        AfterTool {} -> undeclared
        AgentStop {} -> undeclared
    StopHook -> case event of
        AgentStop call running usage -> Right (Just (Ends (Stops (keyOf call.agent) running usage)))
        -- The id of the agent a call stopped is in its input, as @agent_hook.py@ passes it.
        AfterTool _ tool _ input _ ->
            Right
                ( Ends . StopsAgent . AgentId
                    <$> (guard (tool == StopAgent) *> textAt "task_id" input)
                )
        SessionStart {} -> undeclared
        BeforeTool {} -> undeclared
        AgentStart _ -> undeclared
        PromptExpansion _ _ -> undeclared
  where
    lead call want = if isLead steps call.agent then Just (Asks want) else Nothing
    undeclared = Left ("state-hook " <> hookName hook <> " does not run at " <> eventName)
    eventName = case event of
        SessionStart _ _ -> "sessionStart"
        BeforeTool {} -> "beforeTool"
        AfterTool {} -> "afterTool"
        AgentStart _ -> "agentStart"
        PromptExpansion _ _ -> "promptExpansion"
        AgentStop {} -> "agentStop"

{- | How a spawned agent begins: a role that leads a flow runs its own
run, a step runner its steps; any other agent is no business of the flows.
-}
spawnedBegin :: Steps -> AgentRole -> Maybe Begin
spawnedBegin steps spawned = case leads spawned of
    Just _ -> Just SpawnedLead
    Nothing
        | spawned `elem` agentRoles steps -> Just (SpawnedWorker spawned)
        | otherwise -> Nothing

{- | The skills a lead's run begins under, as the skill catalog names them
(@programs/agents/skills/custom@): the engineer's, the 10x's, the architect's
and the chief's.

Typed here, as no source names them apart: the step table's @skills@ (which
the kernel does not read) puts them on the leads' inline steps, and a flow's
name is not its skill's (the @10x@ flow runs under @10x-engineer@).
-}
data LeadSkill = EngineerSkill | TenXSkill | ArchitectSkill | ChiefSkill
    deriving stock (Eq, Show, Enum, Bounded)

-- | The lead skill a name names; 'Nothing' for any other skill.
leadSkill :: Text -> Maybe LeadSkill
leadSkill name = find ((== name) . leadSkillName) [minBound ..]

leadSkillName :: LeadSkill -> Text
leadSkillName = \case
    EngineerSkill -> "engineer"
    TenXSkill -> "10x-engineer"
    ArchitectSkill -> "architect"
    ChiefSkill -> "chief"

{- | What a tool's result binds: a shell command that ran @state init@ binds
its caller to the run init printed, a rerun (a resume) again; a spawn links
its subagent to its span, and binds a flow role's worker, which never inits.
A lead spawned (an engineer) binds itself by its own init, in its own
worktree; any other role is no worker of the run, never under its gates.
-}
bindOf :: Steps -> Tool -> Maybe ToolCallId -> Object -> Value -> Maybe Bind
bindOf steps tool toolCall input output = case tool of
    Shell
        | Just command <- textAt "command" input
        , "state init" `Text.isInfixOf` command ->
            BindSelf <$> (bindingIn =<< textAt "stdout" =<< outputObject)
        | otherwise -> Nothing
    Delegate ->
        (\child -> BindSpawned (AgentId child) toolCall worker)
            <$> (textAt "agentId" =<< outputObject)
      where
        worker = case AgentRole <$> textAt "subagent_type" input of
            Just role | role `elem` flowRoles steps -> Just role
            _ -> Nothing
    Read -> Nothing
    Edit -> Nothing
    Write -> Nothing
    HandbackTool -> Nothing
    Web -> Nothing
    Skill -> Nothing
    StopAgent -> Nothing
    Other -> Nothing
  where
    outputObject = case output of
        Object o -> Just o
        _ -> Nothing

-- | Whose binding a call reads: a subagent's own, else the session's.
keyOf :: Maybe Agent -> Key
keyOf = \case
    Just Agent {agentId = Just agent} -> AgentKey agent
    -- The adapter gives a lead started as an agent (@--agent@) no agent at all.
    Just Agent {agentId = Nothing} -> Main
    Nothing -> Main

-- | Where a want goes: to the caller's run, or into its slot's stash to wait for its binding.
data Delivery = ToRun | Stash Slot
    deriving stock (Eq, Show)

{- | A subagent's hand-back seen before its spawner's hook bound it (a step
runner's) or linked its span (any other's) waits in its stash, which that hook
replays; every other want goes to the caller's run. A subagent with no slot
(no store) has nowhere to wait: its run is none.
-}
delivery ::
    Want -> Key -> Maybe Slot -> Maybe Binding -> Maybe SpanLink -> Delivery
delivery want key slot bound linked = case want of
    HandedBack {} -> waits bound
    SpanHandback {} -> waits linked
    ResumeRun _ -> ToRun
    SpawnRole _ _ -> ToRun
    StartsSpan _ -> ToRun
  where
    waits :: Maybe a -> Delivery
    waits found = case (key, found) of
        (AgentKey _, Nothing) -> maybe ToRun Stash slot
        (AgentKey _, Just _) -> ToRun
        (Main, _) -> ToRun

-- | A hook's text, naming the run it acted on; nothing said is nothing.
aboutRun :: RunId -> Text -> Text
aboutRun run said
    | Text.null said = said
    | otherwise = "run " <> runIdText run <> ": " <> said

-- | A hook's text, naming the run when one is known: none is before the hook found it.
aboutKnown :: Maybe RunId -> Text -> Text
aboutKnown = maybe id aboutRun

-- | The file an edit or write names, joined to the caller's directory: an absolute one stays as it is.
fileOf :: Call -> Object -> Maybe FilePath
fileOf call input = (call.cwd </>) . Text.unpack <$> textAt "file_path" input

textAt :: Text -> Object -> Maybe Text
textAt key input = case KeyMap.lookup (Key.fromText key) input of
    Just (String text) -> Just text
    _ -> Nothing

{- | The lead is no subagent, or one whose role the flows do not know: the
engineer a 10x spawns runs its own flow. A review-lead spawning reviewers is a
worker.
-}
isLead :: Steps -> Maybe Agent -> Bool
isLead steps = \case
    Nothing -> True
    Just agent -> maybe True (`notElem` flowRoles steps) agent.role

-- | Every role a flow spawns: a step's runner, or one spawned beside the advice.
flowRoles :: Steps -> [AgentRole]
flowRoles steps = agentRoles steps <> beside

{- | A role whose hand-back this hook reads: a step's runner. Its spawn is
logged, so the lead hands back only once it returned; a reviewer or checker
spawned beside reports to its spawner alone.
-}
tracked :: Steps -> AgentRole -> Bool
tracked steps role = role `elem` agentRoles steps

-- | The agent's role, when it is a step's runner, whose hand-back the run reads ('tracked').
trackedRole :: Steps -> Agent -> Maybe AgentRole
trackedRole steps agent = case agent.role of
    Just role | tracked steps role -> Just role
    _ -> Nothing

{- | The run's workers of a tracked role, oldest first: those the lead hands
back and restarts after. A span of another role, an Explore agent's, holds
neither.
-}
atWork :: Steps -> RunState -> [Worker]
atWork steps state = filter (tracked steps . (.role)) state.workers

{- | Whether the run records this step runner's hand-back: one also spawned
beside the advice while the run is at a step the role runs, or while the flow
forks its step and the run's 'ledger' has a child of its role open, wherever
the run is. A child run records its own in its parent's run.
-}
followedAt :: Steps -> OpenGraph -> RunState -> AgentRole -> Bool
followedAt steps g state role =
    role `notElem` beside
        || or
            [ stepName s == place.name
            | At place <- [state.at]
            , AnyStep _ (SomeStep s) <- runs
            ]
        || ( any ((== role) . (.role)) (ledger g state)
                && or
                    [ stepName s == metered.step
                    | metered <- forks g state
                    , AnyStep _ (SomeStep s) <- runs
                    ]
           )
  where
    runs = stepsRunBy steps role

{- | What a lead's spawn of this role records: at a fork of the step the
role runs, the spawn of a child the group then waits for. The spawn hook
carries no child id, so a spawn seen twice records twice: none is deduplicated.
-}
spawnedAt :: Steps -> Node -> AgentRole -> Maybe Event
spawnedAt steps at spawned = case at of
    At place ->
        listToMaybe
            [ event
            | AnyStep l (SomeStep s) <- stepsRunBy steps spawned
            , stepName s == place.name
            , Just event <- [opening place.scope l s]
            ]
    Out -> Nothing
    Exit -> Nothing

-- | Whether a lead's spawn of this step's role records the step's spawn: 'spawnedAt's rule, scope aside.
opensChild :: Layer k -> Sing (s :: k) -> Bool
opensChild l s = isJust (opening mempty l s)

-- | The event of a step's spawn of a child: only an action that opens children has one.
opening :: ScopePath -> Layer k -> Sing (s :: k) -> Maybe Event
opening scope l s = case l of
    GatherLayer -> case s of
        Gather.Research -> Just (tookIn scope Gather.ResearchSpawned)
        Gather.Interview -> Nothing
        Gather.Discuss -> Nothing
        Gather.Notes -> Nothing
    PlanLayer -> Nothing
    BuildLayer -> Nothing
    ReviewLayer -> Nothing
    ShipLayer -> Nothing
    TicketLayer -> Nothing
    RequestLayer -> Nothing
    FanLayer -> Nothing
    PickLayer -> Nothing
    FuelLayer -> Nothing

{- | Spawned beside the advised role, never instead of it: a dry-run reviewer
next to the review-lead, a fact-gap researcher, a checker for the full check.
-}
beside :: [AgentRole]
beside = map AgentRole ["reviewer", "researcher", "checker"]

{- | The hooks stay silent on a run that is over, bound by its draft PR to
another branch than HEAD's (@Nothing@: a detached HEAD), or whose drafted PR
GitHub reports merged or closed (@Nothing@: no PR read).
-}
silent ::
    Maybe Branch -> Maybe Readiness -> NonEmpty Envelope -> RunState -> Bool
silent headBranch readiness envelopes state =
    over state
        || maybe
            False
            (\bound -> Just bound /= headBranch || prOver)
            (boundBranch envelopes)
  where
    prOver = case readiness of
        Just IsMerged -> True
        Just IsClosed -> True
        Just IsDraft -> False
        Just IsReady -> False
        Nothing -> False

-- | The branch of the run's latest draft PR not voided, as GitHub reported it.
boundBranch :: NonEmpty Envelope -> Maybe Branch
boundBranch envelopes = case [ draft.branch
                             | Envelope
                                { event = Took _ (AnyOutcome BuildLayer (SomeOutcome _ _ (DraftDone draft)))
                                } <-
                                reverse (fst (unvoided (toList envelopes)))
                             ] of
    branch : _ -> Just branch
    [] -> Nothing

{- | The warning on a spawn off the advice: a flow role that is neither the
advised one nor one spawned beside it. Implementer slices run one after
another, so a later slice spawns while the advice has moved on to the
refactorer. A role outside the flows (Explore, Plan) is no step of the run.
-}
offAdvice :: Steps -> Node -> AgentRole -> AgentRole -> Maybe Text
offAdvice steps at advised spawned
    | spawned `notElem` flowRoles steps = Nothing
    | spawned == advised || spawned `elem` beside = Nothing
    | spawned == AgentRole "implementer"
        && atStep [stepName Build.Implement, stepName Build.Refactor] =
        Nothing
    | otherwise =
        Just
            ( "state: the advice is SPAWN "
                <> roleText advised
                <> ", not "
                <> roleText spawned
            )
  where
    atStep names = case at of
        At place -> place.name `elem` names
        Out -> False
        Exit -> False

{- | What a session start records: a fresh or resumed session lost every
agent the lead had at work, its workers too, so the advice sends them again;
a compacted one lost none. A run with no agent at work records nothing.
-}
restartOf :: Steps -> StartSource -> RunState -> Maybe Event
restartOf steps source state = case source of
    Startup -> lost
    Resumed -> lost
    Compact -> Nothing
  where
    lost =
        if all (Set.null . (.atWork)) state.fans && null (atWork steps state)
            then Nothing
            else Just Restarted

{- | The ids of a hook's records, one per event it appends, in order: a hash
of the run, the agent and its message, so the same hand-back seen twice
appends once (#360 call 18).
-}
hookSources :: RunId -> Agent -> AgentRole -> Text -> [Source]
hookSources run agent (AgentRole role) message =
    [ Hook
        ( digestOf
            [ runIdText run
            , maybe "" (.agentIdText) agent.agentId
            , role
            , message
            , Text.pack (show n)
            ]
        )
    | n <- [0 :: Int ..]
    ]

{- | The id of a span's start: a hash of the run and the call that spawned
it, so a spawn hook fired twice logs once and calls spawned in one message
log one each.
-}
spanStartedSource :: RunId -> ToolCallId -> Source
spanStartedSource run (ToolCallId toolCall) =
    Hook (digestOf [runIdText run, toolCall, "span_started"])

-- | The id of a span's end, however it ended: a span ends once, whichever hook fired first.
spanEndedSource :: RunId -> SpanId -> Source
spanEndedSource run ended =
    Hook (digestOf [runIdText run, Text.pack (show ended.spanSeq), "span_ended"])

-- | The span this call started in these lines, if it did ('spanStartedSource').
spanOfCall :: (Foldable t) => RunId -> ToolCallId -> t Envelope -> Maybe SpanId
spanOfCall run toolCall logged =
    SpanId . (.seq)
        <$> find ((== spanStartedSource run toolCall) . (.source)) logged

-- | A span's start: the spawn, by the harness the session runs on, under the span of its spawner, if any.
spanStartOf :: Harness -> Maybe SpanId -> Spawn -> SpanStart
spanStartOf harness parent spawn =
    SpanStart
        { role = spawn.role
        , harness
        , brief = spawn.brief
        , parent
        , model = spawn.model
        }

{- | A hand-back the log holds already: its first record's id is logged. The
hook then records nothing, not even a refusal of the step it moved past.
-}
loggedAlready :: NonEmpty Envelope -> [Source] -> Bool
loggedAlready envelopes = \case
    first : _ -> any (\envelope -> envelope.source == first) envelopes
    [] -> False

-- | What a hook prints: nothing, or the result of its event.
data Reply
    = Quiet
    | -- | @beforeTool@'s context.
      Allow Text
    | -- | @beforeTool@'s refusal of the call, and why: @route@'s alone.
      Deny Text
    | -- | The context of every other event.
      Note Text
    deriving stock (Eq, Show)

-- | The reply carrying what the run said; an empty text is nothing to say.
replyOf :: Job -> Text -> Reply
replyOf job said
    | Text.null said = Quiet
    | otherwise = toldOf job said

-- | Context only: what a refusal or an error says, never a deny.
toldOf :: Job -> Text -> Reply
toldOf job said = case job of
    Asks (ResumeRun _) -> Note said
    Asks (SpawnRole _ _) -> Allow said
    Asks (StartsSpan _) -> Allow said
    Asks (HandedBack {}) -> Allow said
    Asks (SpanHandback {}) -> Allow said
    Binds _ -> Note said
    Routes _ -> Allow said
    Begins SpawnedLead -> Note said
    Begins (SpawnedWorker _) -> Note said
    Begins (TypedSkill _) -> Note said
    Begins (CalledSkill _) -> Allow said
    -- Any context at an agent's stop keeps it going: a failure there is told nowhere.
    Ends (Stops {}) -> Quiet
    Ends (StopsAgent _) -> Note said

-- | @agent_hook.py@'s @emit_result@: nothing when there is nothing to say.
encodeReply :: Reply -> Maybe LBS.ByteString
encodeReply = \case
    Quiet -> Nothing
    Allow context ->
        Just (encode (object ["decision" .= ("allow" :: Text), "context" .= context]))
    Deny reason -> Just (encode (object ["decision" .= ("deny" :: Text), "reason" .= reason]))
    Note context -> Just (encode (object ["context" .= context]))
