{- | The hooks that keep a run's record as the agents work, without the model
remembering to (#360's hooks contract): the neutral hook event in
(programs/agents/hooks/agent_hook.py), what the run is asked, and the reply out.

@
resume    sessionStart          a fresh or resumed session records restarted; context: show and next
spawn     beforeTool delegate   context: next, and a warning off the advice
handback  beforeTool handback   records a worker's hand-back; context: what it recorded
asked     afterTool ask         the answer lines of questions awaiting the user
bind      afterTool shell       binds the agent to the run its @state init@ started or resumed
          afterTool delegate    binds a worker spawned to its spawner's run; records a hand-back it made first
route     beforeTool shell      denies a @state@ command aimed at another run than the agent's
          beforeTool edit,      denies an unbound lead's write: an edit, a commit, a push, a PR
          write, delegate       opened or merged, a spawn
begin     agentStart            context: how a spawned lead begins, or a worker's brief
          promptExpansion       context: how a typed lead skill begins; marks the agent a lead
          beforeTool skill      context: how a called lead skill begins; marks the agent a lead
@

Each finds the caller's run through its binding ("State.Protocol.Binding"),
and its reply names the run it acted on; @begin@ reads no run.

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
    Agent (..),
    Tool (..),
    StartSource (..),
    parseHookEvent,
    Job (..),
    Want (..),
    Bind (..),
    Begin (..),
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
    tracked,
    spawnedAt,
    hookSources,
    restartOf,
    loggedAlready,
    Reply (..),
    replyOf,
    toldOf,
    encodeReply,
    awaitingUser,
) where

import Control.Monad (guard)
import Data.Aeson (Object, Value (..), eitherDecode, encode, object, withObject, (.:), (.=))
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
import State.Category.Flow (ScopePath)
import State.Category.Graph (Node (..), Place (..))
import State.Category.Step (Sing, SomeOutcome (..), SomeStep (..), stepName)
import State.Protocol.Advice (Readiness (..))
import State.Protocol.Binding (AgentId (..), Binding (..), Key (..), Slot, bindingIn)
import State.Role (leads)
import State.Run.Ask (Principal (..), Question (..), qidText)
import State.Run.Event (AgentRole (..), Asking (..), Branch, DraftPr (..), Envelope (..), Event (Restarted, Took), RunId, SessionId (..), Source (..), Start (..), roleText, runIdText, tookIn)
import State.Run.Fan (Fan (..))
import State.Run.Fold (Pending (..), RunState (..), Waits (..), over, unvoided)
import State.Run.Id (digestOf)
import State.Step.Build (Outcome (DraftDone))
import State.Step.Build qualified as Build
import State.Step.Catalog (AnyOutcome (..), AnyStep (..), Layer (..))
import State.Step.Choice (choiceNamed, nodeChoice)
import State.Step.Gather qualified as Gather
import State.Table (Steps, agentRoles, stepsRunBy)

data HookName = ResumeHook | SpawnHook | HandbackHook | AskedHook | BindHook | RouteHook | BeginHook
    deriving stock (Eq, Show, Enum, Bounded)

-- | As @kernel/hooks.nix@ names them on the command line.
hookName :: HookName -> Text
hookName = \case
    ResumeHook -> "resume"
    SpawnHook -> "spawn"
    HandbackHook -> "handback"
    AskedHook -> "asked"
    BindHook -> "bind"
    RouteHook -> "route"
    BeginHook -> "begin"

-- | What the hook does, as @state-hook --help@ lists it.
hookPurpose :: HookName -> Text
hookPurpose = \case
    ResumeHook -> "At session start: prints the run and its next action"
    SpawnHook -> "Before a delegate: next, and a warning off the advice"
    HandbackHook -> "Before a hand-back: records it, printing the record"
    AskedHook -> "After an ask: answer lines of questions to the user"
    BindHook -> "After a shell or delegate: binds the agent to its run"
    RouteHook -> "Denies a state call off its run, a write before init"
    BeginHook -> "At a spawn or a lead skill: how its work begins"

-- | One event of the neutral contract. @history@ and @context@ are required, never read.
data HookEvent
    = SessionStart Call StartSource
    | BeforeTool Call Tool Object
    | -- | The tool's input, and its output as the client gave it.
      AfterTool Call Tool Object Value
    | -- | A subagent starts, before its first turn.
      AgentStart Call
    | -- | A typed @/name@ expanded to its skill or command, by that name.
      PromptExpansion Call Text
    deriving stock (Eq, Show)

data Call = Call {session :: SessionId, cwd :: FilePath, agent :: Maybe Agent}
    deriving stock (Eq, Show)

callOf :: HookEvent -> Call
callOf = \case
    SessionStart call _ -> call
    BeforeTool call _ _ -> call
    AfterTool call _ _ _ -> call
    AgentStart call -> call
    PromptExpansion call _ -> call

-- | The subagent making the call; the lead is none. Either field is absent when its agent gives none.
data Agent = Agent {agentId :: Maybe AgentId, role :: Maybe AgentRole}
    deriving stock (Eq, Show)

-- | @vocabulary.json@'s tools, in its order.
data Tool = Shell | Read | Edit | Write | Delegate | HandbackTool | Ask | Web | Skill | Other
    deriving stock (Eq, Show, Enum, Bounded)

-- | Why a session started: @vocabulary.json@'s sources, in its order.
data StartSource = Startup | Resumed | Compact
    deriving stock (Eq, Show, Enum, Bounded)

-- | The event on stdin; an unknown event, tool or source is an error, as in @agent_hook.py@.
parseHookEvent :: LBS.ByteString -> Either Text HookEvent
parseHookEvent input = either (Left . Text.pack) Right $ do
    value <- eitherDecode input
    flip parseEither value $ withObject "hook event" $ \o -> do
        call <- Call . SessionId <$> o .: "session" <*> o .: "cwd" <*> (o .: "agent" >>= agentOf)
        (o .: "event" :: Parser Text) >>= \case
            "sessionStart" -> SessionStart call <$> (o .: "source" >>= named "source" startSourceName)
            "beforeTool" -> do
                _ <- o .: "history" :: Parser [Text]
                BeforeTool call <$> tool o <*> o .: "input"
            "afterTool" -> do
                _ <- o .: "context" :: Parser Value
                AfterTool call <$> tool o <*> o .: "input" <*> o .: "output"
            "agentStart" -> pure (AgentStart call)
            "promptExpansion" -> PromptExpansion call <$> o .: "skill"
            other -> fail ("no event " <> Text.unpack other <> ": sessionStart, beforeTool, afterTool, agentStart or promptExpansion")
  where
    tool o = o .: "tool" >>= named "tool" toolName
    agentOf = \case
        Null -> pure Nothing
        value -> withObject "agent" (\a -> Just <$> (Agent . fmap AgentId <$> a .: "id" <*> (fmap AgentRole <$> a .: "role"))) value
    named :: (Enum a, Bounded a) => String -> (a -> Text) -> Text -> Parser a
    named what name raw = maybe (fail ("no " <> what <> " " <> Text.unpack raw)) pure (lookup raw [(name x, x) | x <- [minBound .. maxBound]])

toolName :: Tool -> Text
toolName = \case
    Shell -> "shell"
    Read -> "read"
    Edit -> "edit"
    Write -> "write"
    Delegate -> "delegate"
    HandbackTool -> "handback"
    Ask -> "ask"
    Web -> "web"
    Skill -> "skill"
    Other -> "other"

startSourceName :: StartSource -> Text
startSourceName = \case
    Startup -> "startup"
    Resumed -> "resume"
    Compact -> "compact"

{- | What a hook does: ask the caller's run, bind an agent to its run, route
a call to the agent's run, or tell how work begins.
-}
data Job = Asks Want | Binds Bind | Routes Gate | Begins Begin
    deriving stock (Eq, Show)

-- | A call @route@ weighs: a shell command (its text), or a write no run may miss.
data Gate = RunsShell Text | Edits | Writes | Spawns
    deriving stock (Eq, Show)

-- | What a hook asks of the worktree's run.
data Want
    = -- | Why the session started.
      ResumeRun StartSource
    | -- | The role the lead spawns, when its input names one.
      SpawnRole (Maybe AgentRole)
    | -- | A flow role's hand-back: its message, and who sent it.
      HandedBack Text Agent AgentRole
    | AskedUser
    deriving stock (Eq, Show)

data Bind
    = -- | The caller to the run its @state init@ printed.
      BindSelf Binding
    | -- | A worker the caller spawned, by its agent id and role, to the caller's run.
      BindChild AgentId AgentRole
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

{- | What the hook asks of the run, 'Nothing' when it has nothing to do: a
subagent's spawn or question, or a hand-back the run does not follow (a
reviewer's goes to its review-lead). A hook at an event it is not declared on
is an error.
-}
wants :: Steps -> HookName -> HookEvent -> Either Text (Maybe Job)
wants steps hook event = case hook of
    ResumeHook -> case event of
        SessionStart call source -> Right (lead call (ResumeRun source))
        BeforeTool {} -> undeclared
        AfterTool {} -> undeclared
        AgentStart _ -> undeclared
        PromptExpansion _ _ -> undeclared
    SpawnHook -> case event of
        BeforeTool call _ input -> Right (lead call (SpawnRole (AgentRole <$> textAt "subagent_type" input)))
        SessionStart {} -> undeclared
        AfterTool {} -> undeclared
        AgentStart _ -> undeclared
        PromptExpansion _ _ -> undeclared
    HandbackHook -> case event of
        BeforeTool call _ input -> Right $ case (call.agent, textAt "message" input) of
            (Just agent@Agent {role = Just role}, Just message) | tracked steps role -> Just (Asks (HandedBack message agent role))
            _ -> Nothing
        SessionStart {} -> undeclared
        AfterTool {} -> undeclared
        AgentStart _ -> undeclared
        PromptExpansion _ _ -> undeclared
    AskedHook -> case event of
        AfterTool call _ _ _ -> Right (lead call AskedUser)
        SessionStart {} -> undeclared
        BeforeTool {} -> undeclared
        AgentStart _ -> undeclared
        PromptExpansion _ _ -> undeclared
    BindHook -> case event of
        AfterTool _ tool input output -> Right (Binds <$> bindOf steps tool input output)
        SessionStart {} -> undeclared
        BeforeTool {} -> undeclared
        AgentStart _ -> undeclared
        PromptExpansion _ _ -> undeclared
    RouteHook -> case event of
        BeforeTool _ tool input ->
            Right $
                Routes <$> case tool of
                    Shell -> RunsShell <$> textAt "command" input
                    Edit -> Just Edits
                    Write -> Just Writes
                    Delegate -> Just Spawns
                    Read -> Nothing
                    HandbackTool -> Nothing
                    Ask -> Nothing
                    Web -> Nothing
                    Skill -> Nothing
                    Other -> Nothing
        SessionStart {} -> undeclared
        AfterTool {} -> undeclared
        AgentStart _ -> undeclared
        PromptExpansion _ _ -> undeclared
    BeginHook -> case event of
        AgentStart call -> Right (Begins <$> (spawnedBegin steps =<< (.role) =<< call.agent))
        PromptExpansion _ skill -> Right (Begins . TypedSkill <$> leadSkill skill)
        BeforeTool _ tool input -> Right (Begins . CalledSkill <$> (guard (tool == Skill) *> textAt "skill" input >>= leadSkill))
        SessionStart {} -> undeclared
        AfterTool {} -> undeclared
  where
    lead call want = if isLead steps call.agent then Just (Asks want) else Nothing
    undeclared = Left ("state-hook " <> hookName hook <> " does not run at " <> eventName)
    eventName = case event of
        SessionStart _ _ -> "sessionStart"
        BeforeTool {} -> "beforeTool"
        AfterTool {} -> "afterTool"
        AgentStart _ -> "agentStart"
        PromptExpansion _ _ -> "promptExpansion"

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
the kernel does not read) puts them on the leads' inline steps beside
@engineering@, which begins no run, and a flow's name is not its skill's
(the @10x@ flow runs under @10x-engineer@).
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
its caller to the run init printed, a rerun (a resume) again; a spawn of a
flow role binds the worker, which never inits. A lead spawned (an engineer)
binds itself by its own init, in its own worktree.
-}
bindOf :: Steps -> Tool -> Object -> Value -> Maybe Bind
bindOf steps tool input output = case tool of
    Shell
        | Just command <- textAt "command" input
        , "state init" `Text.isInfixOf` command ->
            BindSelf <$> (bindingIn =<< textAt "stdout" =<< outputObject)
        | otherwise -> Nothing
    Delegate -> case (textAt "agentId" =<< outputObject, AgentRole <$> textAt "subagent_type" input) of
        (Just child, Just role) | role `elem` flowRoles steps -> Just (BindChild (AgentId child) role)
        _ -> Nothing
    Read -> Nothing
    Edit -> Nothing
    Write -> Nothing
    HandbackTool -> Nothing
    Ask -> Nothing
    Web -> Nothing
    Skill -> Nothing
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

{- | A worker's hand-back seen before its spawner's hook bound it waits in the
worker's stash, which that hook replays; every other want goes to the caller's
run. A subagent with no slot (no store) has nowhere to wait: its run is none.
-}
delivery :: Want -> Key -> Maybe Slot -> Maybe Binding -> Delivery
delivery want key slot bound = case want of
    HandedBack {} -> case (key, bound) of
        (AgentKey _, Nothing) -> maybe ToRun Stash slot
        (AgentKey _, Just _) -> ToRun
        (Main, _) -> ToRun
    ResumeRun _ -> ToRun
    SpawnRole _ -> ToRun
    AskedUser -> ToRun

-- | A hook's text, naming the run it acted on; nothing said is nothing.
aboutRun :: RunId -> Text -> Text
aboutRun run said
    | Text.null said = said
    | otherwise = "run " <> runIdText run <> ": " <> said

-- | A hook's text, naming the run when one is known: none is before the hook found it.
aboutKnown :: Maybe RunId -> Text -> Text
aboutKnown = maybe id aboutRun

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

{- | Whether the run records this step runner's hand-back where it is: one
also spawned beside the advice only at a choice, where it runs an action. A
child run records its own in its parent's run.
-}
followedAt :: Node -> AgentRole -> Bool
followedAt at role = role `notElem` beside || isJust (nodeChoice at)

{- | What a lead's spawn of this role records: at a choice, the spawn of the
action the role runs, a child the choice then waits for. The spawn hook
carries no child id, so a spawn seen twice records twice: none is deduplicated.
-}
spawnedAt :: Steps -> Node -> AgentRole -> Maybe Event
spawnedAt steps at spawned = case at of
    At place
        | Just _ <- choiceNamed place.name ->
            listToMaybe [event | AnyStep l (SomeStep s) <- stepsRunBy steps spawned, Just event <- [opening place.scope l s]]
        | otherwise -> Nothing
    Out -> Nothing
    Exit -> Nothing

-- | The event of a step's spawn of a child: only an action that opens children has one.
opening :: ScopePath -> Layer k -> Sing (s :: k) -> Maybe Event
opening scope l s = case l of
    GatherLayer -> case s of
        Gather.Research -> Just (tookIn scope Gather.ResearchSpawned)
        Gather.Interview -> Nothing
        Gather.Discuss -> Nothing
    PlanLayer -> Nothing
    BuildLayer -> Nothing
    ReviewLayer -> Nothing
    ShipLayer -> Nothing
    TicketLayer -> Nothing
    RequestLayer -> Nothing
    FanLayer -> Nothing
    ChoiceLayer -> Nothing
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
silent :: Maybe Branch -> Maybe Readiness -> NonEmpty Envelope -> RunState -> Bool
silent headBranch readiness envelopes state = over state || maybe False (\bound -> Just bound /= headBranch || prOver) (boundBranch envelopes)
  where
    prOver = case readiness of
        Just IsMerged -> True
        Just IsClosed -> True
        Just IsDraft -> False
        Just IsReady -> False
        Nothing -> False

-- | The branch of the run's latest draft PR not voided, as GitHub reported it.
boundBranch :: NonEmpty Envelope -> Maybe Branch
boundBranch envelopes = case [draft.branch | Envelope {event = Took _ (AnyOutcome BuildLayer (SomeOutcome _ _ (DraftDone draft)))} <- reverse (fst (unvoided (toList envelopes)))] of
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
    | spawned == AgentRole "implementer" && atStep [stepName Build.Implement, stepName Build.Refactor] = Nothing
    | otherwise = Just ("state: the advice is SPAWN " <> roleText advised <> ", not " <> roleText spawned)
  where
    atStep names = case at of
        At place -> place.name `elem` names
        Out -> False
        Exit -> False

{- | What a session start records: a fresh or resumed session lost every
agent the lead had at work, its workers too, so the advice sends them again;
a compacted one lost none. A run with no agent at work records nothing.
-}
restartOf :: StartSource -> RunState -> Maybe Event
restartOf source state = case source of
    Startup -> lost
    Resumed -> lost
    Compact -> Nothing
  where
    lost = if all (Set.null . (.atWork)) state.fans && null state.live then Nothing else Just Restarted

{- | The ids of a hook's records, one per event it appends, in order: a hash
of the run, the agent and its message, so the same hand-back seen twice
appends once (#360 call 18).
-}
hookSources :: RunId -> Agent -> AgentRole -> Text -> [Source]
hookSources run agent (AgentRole role) message =
    [Hook (digestOf [runIdText run, maybe "" (.agentIdText) agent.agentId, role, message, Text.pack (show n)]) | n <- [0 :: Int ..]]

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
    Asks AskedUser -> Note said
    Asks (SpawnRole _) -> Allow said
    Asks (HandedBack {}) -> Allow said
    Binds _ -> Note said
    Routes _ -> Allow said
    Begins SpawnedLead -> Note said
    Begins (SpawnedWorker _) -> Note said
    Begins (TypedSkill _) -> Note said
    Begins (CalledSkill _) -> Allow said

-- | @agent_hook.py@'s @emit_result@: nothing when there is nothing to say.
encodeReply :: Reply -> Maybe LBS.ByteString
encodeReply = \case
    Quiet -> Nothing
    Allow context -> Just (encode (object ["decision" .= ("allow" :: Text), "context" .= context]))
    Deny reason -> Just (encode (object ["decision" .= ("deny" :: Text), "reason" .= reason]))
    Note context -> Just (encode (object ["context" .= context]))

{- | After the lead put a question to the user: the line recording each answer
still awaited. A run started by a parent asks it, not the user.
-}
awaitingUser :: RunState -> [Text]
awaitingUser state = case state.start.principal of
    ByUser _ -> ["state: record the user's answer: state answer " <> qidText p.asking.question.qid <> " <answer>" | p <- state.pending, p.waits == ForAnswer]
    ByRole {} -> []
