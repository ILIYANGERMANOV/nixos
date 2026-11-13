{- | The hooks that keep a run's record as the agents work, without the model
remembering to (#360's hooks contract): the neutral hook event in
(programs/agents/hooks/agent_hook.py), what the run is asked, and the reply out.

@
resume    sessionStart          context: show and next
spawn     beforeTool delegate   context: next, and a warning off the advice
handback  beforeTool handback   records the hand-back; appends what it recorded
asked     afterTool ask         the answer lines of questions awaiting the user
@

None denies: a refusal or an error becomes context (fail open and tell). Only
the lead steers: a subagent's spawn or question is ignored, but a hand-back,
which only a subagent makes.
-}
module State.Hook (
    HookName (..),
    hookName,
    parseHookName,
    HookEvent (..),
    Call (..),
    callOf,
    Agent (..),
    Tool (..),
    StartSource (..),
    parseHookEvent,
    Want (..),
    wants,
    silent,
    offAdvice,
    hookSources,
    loggedAlready,
    Reply (..),
    replyOf,
    toldOf,
    encodeReply,
    awaitingUser,
) where

import Data.Aeson (Object, Value (..), eitherDecode, encode, object, withObject, (.:), (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.Bits (xor)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.List.NonEmpty (NonEmpty)
import Data.Maybe (catMaybes, fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)
import Data.Word (Word64, Word8)
import Numeric (showHex)
import State.Advice (Readiness (..))
import State.Ask (Principal (..), Question (..), qidText)
import State.Cap (stepName)
import State.Cap qualified as Cap
import State.Event (AgentRole (..), Asking (..), Branch, Digest (..), DraftPr (..), Envelope (..), Event (Took), Outcome (DraftDone), RunId, Source (..), Start (..), roleText, runIdText)
import State.Fold (Pending (..), RunState (..), Waits (..))
import State.Graph (Node (..), Place (..))
import State.Steps (Steps, agentRoles)

data HookName = ResumeHook | SpawnHook | HandbackHook | AskedHook
    deriving stock (Eq, Show, Enum, Bounded)

-- | As @kernel/hooks.nix@ names them on the command line.
hookName :: HookName -> Text
hookName = \case
    ResumeHook -> "resume"
    SpawnHook -> "spawn"
    HandbackHook -> "handback"
    AskedHook -> "asked"

parseHookName :: [Text] -> Maybe HookName
parseHookName = \case
    [name] -> lookup name [(hookName hook, hook) | hook <- [minBound .. maxBound]]
    _ -> Nothing

-- | One event of the neutral contract. @history@, @output@ and @context@ are required, never read.
data HookEvent
    = SessionStart Call StartSource
    | BeforeTool Call Tool Object
    | AfterTool Call Tool
    deriving stock (Eq, Show)

data Call = Call {session :: Text, cwd :: FilePath, agent :: Maybe Agent}
    deriving stock (Eq, Show)

callOf :: HookEvent -> Call
callOf = \case
    SessionStart call _ -> call
    BeforeTool call _ _ -> call
    AfterTool call _ -> call

-- | The subagent making the call; the lead is none. Either field is absent when its agent gives none.
data Agent = Agent {agentId :: Maybe Text, role :: Maybe AgentRole}
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
        call <- Call <$> o .: "session" <*> o .: "cwd" <*> (o .: "agent" >>= agentOf)
        (o .: "event" :: Parser Text) >>= \case
            "sessionStart" -> SessionStart call <$> (o .: "source" >>= named "source" startSourceName)
            "beforeTool" -> do
                _ <- o .: "history" :: Parser [Text]
                BeforeTool call <$> tool o <*> o .: "input"
            "afterTool" -> do
                _ <- o .: "input" :: Parser Object
                _ <- o .: "output" :: Parser Value
                _ <- o .: "context" :: Parser Value
                AfterTool call <$> tool o
            other -> fail ("no event " <> Text.unpack other <> ": sessionStart, beforeTool or afterTool")
  where
    tool o = o .: "tool" >>= named "tool" toolName
    agentOf = \case
        Null -> pure Nothing
        value -> withObject "agent" (\a -> Just <$> (Agent <$> a .: "id" <*> (fmap AgentRole <$> a .: "role"))) value
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

-- | What a hook asks of the worktree's run.
data Want
    = ResumeRun
    | -- | The role the lead spawns, when its input names one.
      SpawnRole (Maybe AgentRole)
    | -- | A flow role's hand-back: the tool's input, its message, and who sent it.
      HandedBack Object Text Agent AgentRole
    | AskedUser
    deriving stock (Eq, Show)

{- | What the hook asks of the run, 'Nothing' when it has nothing to do: a
subagent's spawn or question, or a hand-back the run does not follow (a
reviewer's goes to its review-lead). A hook at an event it is not declared on
is an error.
-}
wants :: Steps -> HookName -> HookEvent -> Either Text (Maybe Want)
wants steps hook event = case hook of
    ResumeHook -> case event of
        SessionStart call _ -> Right (lead call ResumeRun)
        BeforeTool {} -> undeclared
        AfterTool {} -> undeclared
    SpawnHook -> case event of
        BeforeTool call _ input -> Right (lead call (SpawnRole (AgentRole <$> textAt "subagent_type" input)))
        SessionStart {} -> undeclared
        AfterTool {} -> undeclared
    HandbackHook -> case event of
        BeforeTool call _ input -> Right $ case (call.agent, textAt "message" input) of
            (Just agent@Agent {role = Just role}, Just message) | role `elem` followed steps -> Just (HandedBack input message agent role)
            _ -> Nothing
        SessionStart {} -> undeclared
        AfterTool {} -> undeclared
    AskedHook -> case event of
        AfterTool call _ -> Right (lead call AskedUser)
        SessionStart {} -> undeclared
        BeforeTool {} -> undeclared
  where
    lead call want = if isLead steps call.agent then Just want else Nothing
    undeclared = Left ("state-hook " <> hookName hook <> " does not run at " <> eventName)
    eventName = case event of
        SessionStart _ _ -> "sessionStart"
        BeforeTool {} -> "beforeTool"
        AfterTool _ _ -> "afterTool"

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

-- | The roles whose hand-back the run records: a step's runner, not one spawned beside it.
followed :: Steps -> [AgentRole]
followed steps = filter (`notElem` beside) (agentRoles steps)

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
silent headBranch readiness envelopes state = over || maybe False (\bound -> Just bound /= headBranch || prOver) (boundBranch envelopes)
  where
    prOver = case readiness of
        Just IsMerged -> True
        Just IsClosed -> True
        Just IsDraft -> False
        Just IsReady -> False
        Nothing -> False
    over = case (state.stopped, state.at) of
        (Just _, _) -> True
        (Nothing, At _) -> False
        (Nothing, Out) -> True
        (Nothing, Exit) -> True

-- | The branch of the run's latest draft PR, as GitHub reported it.
boundBranch :: NonEmpty Envelope -> Maybe Branch
boundBranch envelopes = case [draft.branch | Envelope {event = Took (DraftDone draft)} <- reverse (foldr (:) [] envelopes)] of
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
    | spawned == AgentRole "implementer" && atStep [stepName Cap.Implement, stepName Cap.Refactor] = Nothing
    | otherwise = Just ("state: the advice is SPAWN " <> roleText advised <> ", not " <> roleText spawned)
  where
    atStep names = case at of
        At place -> place.name `elem` names
        Out -> False
        Exit -> False

{- | The ids of a hook's records, one per event it appends, in order: a hash
of the run, the agent and its message, so the same hand-back seen twice
appends once (#360 call 18).
-}
hookSources :: RunId -> Agent -> AgentRole -> Text -> [Source]
hookSources run agent (AgentRole role) message =
    [Hook (Digest (fnv1a (Text.intercalate "\0" [runIdText run, fromMaybe "" agent.agentId, role, message, Text.pack (show n)]))) | n <- [0 :: Int ..]]

{- | A hand-back the log holds already: its first record's id is logged. The
hook then records nothing, not even a refusal of the step it moved past.
-}
loggedAlready :: NonEmpty Envelope -> [Source] -> Bool
loggedAlready envelopes = \case
    first : _ -> any (\envelope -> envelope.source == first) envelopes
    [] -> False

-- | FNV-1a, 64 bits, over the text's UTF-8, in hex: a dedupe key, no security.
fnv1a :: Text -> Text
fnv1a = Text.pack . (`showHex` "") . BS.foldl' step 0xcbf29ce484222325 . encodeUtf8
  where
    step :: Word64 -> Word8 -> Word64
    step hash byte = (hash `xor` fromIntegral byte) * 0x100000001b3

-- | What a hook prints: nothing, or the result of its event.
data Reply
    = Quiet
    | -- | @beforeTool@'s: the input rewritten, context, or both absent.
      Allow (Maybe Object) (Maybe Text)
    | -- | @sessionStart@'s and @afterTool@'s.
      Note Text
    deriving stock (Eq, Show)

-- | The reply carrying what the run said; an empty text is nothing to say.
replyOf :: Want -> Text -> Reply
replyOf want said
    | Text.null said = Quiet
    | otherwise = case want of
        HandedBack input message _ _ -> Allow (Just (KeyMap.insert "message" (String (message <> "\n\n" <> said)) input)) Nothing
        ResumeRun -> toldOf want said
        SpawnRole _ -> toldOf want said
        AskedUser -> toldOf want said

-- | Context only: what a refusal or an error says, never a deny.
toldOf :: Want -> Text -> Reply
toldOf want said = case want of
    ResumeRun -> Note said
    AskedUser -> Note said
    SpawnRole _ -> Allow Nothing (Just said)
    HandedBack {} -> Allow Nothing (Just said)

-- | @agent_hook.py@'s @emit_result@: nothing when there is nothing to say.
encodeReply :: Reply -> Maybe LBS.ByteString
encodeReply = \case
    Quiet -> Nothing
    Allow updated context -> Just (encode (object (("decision" .= ("allow" :: Text)) : catMaybes [("updatedInput" .=) <$> updated, ("context" .=) <$> context])))
    Note context -> Just (encode (object ["context" .= context]))

{- | After the lead put a question to the user: the line recording each answer
still awaited. A run started by a parent asks it, not the user.
-}
awaitingUser :: RunState -> [Text]
awaitingUser state = case state.start.principal of
    ByUser -> ["state: record the user's answer: state answer " <> qidText p.asking.question.qid <> " <answer>" | p <- state.pending, p.waits == ForAnswer]
    ByRole _ _ -> []
