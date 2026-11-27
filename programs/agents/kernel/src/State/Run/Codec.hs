{- | An event's payload as the store keeps it: its type, and one JSON object
whose keys the type names, such as @review.rows@ with
@{"head":"abc123"}@. A step event's @type@ is its edge's name in the flow's
graph. The columns around it are "Data.Payload.Event"'s.
-}
module State.Run.Codec (
    schemaVersion,
    payloadText,
    decodePayload,
    eventType,
    areaText,
    reasonText,
    stopToken,
    stopWire,
    parseStopLine,
    judgementText,
    flowText,
    opText,
    waitingText,
    shaText,
    urlText,
    taskIdText,
    branchText,
    repoText,
    taskStateName,
    taskStateArgs,
    prStates,
    topicText,
    decodeBreakdown,
    decodeTask,
) where

import Data.Aeson (
    Key,
    Object,
    Value (..),
    eitherDecodeStrictText,
    withObject,
    (.:),
    (.:?),
    (.=),
 )
import Data.Aeson.Encoding (
    Encoding,
    encodingToLazyByteString,
    null_,
    pair,
    pairs,
    text,
 )
import Data.Aeson.Types (Parser, Series, parseEither)
import Data.Bifunctor (first)
import Data.Functor ((<&>))
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Lazy qualified as Lazy
import Data.Text.Lazy.Encoding qualified as Lazy
import State.Category.Flow (unqualify)
import State.Category.Fuel (parseByName)
import State.Category.Step (eventText)
import State.Role (drawnDecoders, flowText)
import State.Run.Ask (
    Above (..),
    Basis (..),
    Kind (Security),
    OneLine,
    Proposal (..),
    QId,
    Question (..),
    kindName,
    oneLineText,
    parseKind,
    parseOneLine,
    parseQId,
    qidText,
 )
import State.Run.Event (
    AgentId (..),
    AgentRole (..),
    AnyOutcome,
    Asker (..),
    Asking (..),
    Child (..),
    ChildTask (..),
    Event (..),
    Link (..),
    Note (..),
    Op (..),
    Parent (..),
    Principal (..),
    Reply (..),
    RunId,
    Said (..),
    Start (..),
    StateName (..),
    Stop (..),
    StopReason (..),
    TaskId (..),
    TaskNo,
    TaskState (..),
    Url (..),
    Waiting (..),
    parseRunId,
    parseTaskNo,
    runIdText,
    taskNoText,
    tookEvent,
 )
import State.Run.Id (eventIdText, parseEventId)
import State.Step.Artifact (
    Shape (..),
    areaText,
    branchText,
    decodeBreakdown,
    decodeTask,
    judgementText,
    named,
    planData,
    planOf,
    repoText,
    shaText,
    shapeData,
    shapeOf,
    targetData,
    targetOf,
    taskEncoding,
    taskIdText,
    topicText,
    urlData,
    urlOf,
    urlText,
 )
import State.Step.Artifact qualified as Artifact
import State.Step.Catalog (outcomeData, outcomeDecoders)

{- | The payload version every event type has in the store, from 1: a
change of one type's shape bumps that type's.
-}
schemaVersion :: Int
schemaVersion = 1

-- | An event's payload, the store's @data@: one JSON object, its keys by type.
payloadText :: Event -> Text
payloadText =
    Lazy.toStrict . Lazy.decodeUtf8 . encodingToLazyByteString . pairs . eventData

-- | The event of this type whose payload this is, or why it does not read.
decodePayload :: Text -> Text -> Either Text Event
decodePayload kind raw =
    first
        Text.pack
        (eitherDecodeStrictText raw >>= parseEither (withObject "data" (eventOf kind)))

eventType :: Event -> Text
eventType = \case
    Started _ -> "started"
    Targeted _ -> "target"
    Extended _ -> "extend"
    Gapped _ -> "gap"
    Took scope outcome -> eventText (tookEvent scope outcome)
    Stopped _ -> "stop"
    Overridden _ _ -> "overridden"
    Refused _ -> "refused"
    Asked _ -> "asked"
    RetaggedSecurity _ -> "retagged"
    RuledOn _ _ -> "ruled"
    Forwarded _ _ -> "forwarded"
    Answered {} -> "answered"
    QuestionParked _ _ -> "parked"
    Spawning _ -> "spawning"
    Spawned _ -> "spawned"
    Resumed _ -> "resumed"
    HandedBack _ _ -> "handed_back"
    TaskMoved _ _ -> "task"
    Held _ _ -> "held"
    ActedOn _ _ -> "acted"
    TaskAdded _ -> "task_added"
    Restarted -> "restarted"
    WorkerHandedBack _ _ -> "worker_handed_back"
    WorkerSpawned _ _ -> "worker_spawned"
    WorkerReturned _ _ -> "worker_returned"
    AgentEnded _ -> "agent_ended"
    Suspended _ _ -> "suspended"
    Focused _ -> "focused"
    Voided _ _ -> "voided"

eventData :: Event -> Series
eventData = \case
    Started start ->
        "flow" .= flowText start.flow
            <> "notes" .= start.notes
            <> pair "principal" (principalEncoding start.principal)
            <> "interface" .= map opText (Set.toList start.interface)
    Targeted target -> targetData target
    Extended why -> "why" .= why
    Gapped gap -> "text" .= gap
    Took _ outcome -> outcomeData outcome
    Stopped stop -> "reason" .= reasonText stop.reason <> "why" .= stop.why
    Overridden (StateName to) why -> "to" .= to <> "why" .= why
    Refused note -> "message" .= note.message <> "fix" .= note.fix
    Asked Asking {question, step = StateName step, from} ->
        qidData question.qid
            <> "kind" .= kindName question.kind
            <> "question" .= oneLineText question.text
            <> "step" .= step
            <> pair "from" (askerEncoding from)
    -- #360 writes the kind, though it is only ever Security.
    RetaggedSecurity qid -> qidData qid <> "kind" .= kindName Security
    RuledOn qid proposal ->
        qidData qid
            <> "answer" .= oneLineText proposal.answer
            <> "why" .= oneLineText proposal.why
            <> "cost" .= oneLineText proposal.cost
            <> pair "basis" (maybe null_ basisEncoding proposal.basis)
    Forwarded qid to -> qidData qid <> pair "to" (aboveEncoding to)
    Answered qid reply by -> qidData qid <> replyData reply <> pair "by" (aboveEncoding by)
    QuestionParked qid why -> qidData qid <> "why" .= oneLineText why
    Spawned child ->
        "child" .= runIdText child.run
            <> childTaskData child.task
            <> "worktree" .= child.worktree
    Spawning task -> "task" .= taskIdText task
    Resumed child -> "child" .= runIdText child
    HandedBack child said -> "child" .= runIdText child <> saidData said
    TaskMoved task moved -> "task" .= taskIdText task <> taskStateData moved
    Held task url -> "task" .= taskIdText task <> urlData url
    ActedOn task url -> "task" .= taskIdText task <> urlData url
    TaskAdded task -> pair "task" (taskEncoding task)
    Restarted -> mempty
    WorkerHandedBack (AgentRole role) line -> "role" .= role <> "line" .= oneLineText line
    WorkerSpawned (AgentRole role) agent -> "role" .= role <> "agent" .= agent.agentIdText
    WorkerReturned (AgentRole role) agent -> "role" .= role <> "agent" .= fmap (.agentIdText) agent
    AgentEnded agent -> "agent" .= agent.agentIdText
    Suspended task summary -> "request" .= taskNoText task <> "summary" .= oneLineText summary
    Focused task -> "request" .= taskNoText task
    Voided n why -> "seq" .= n <> "why" .= why
  where
    qidData qid = "qid" .= qidText qid

eventOf :: Text -> Object -> Parser Event
eventOf kind obj = case kind of
    "started" -> Started <$> startOf obj
    "target" -> Targeted <$> targetOf obj
    "extend" -> Extended <$> obj .: "why"
    "gap" -> Gapped <$> obj .: "text"
    "stop" ->
        Stopped
            <$> ( Stop
                    <$> (obj .: "reason" >>= named "stop reason" (parseByName reasonText))
                    <*> obj .: "why"
                )
    "overridden" -> Overridden . StateName <$> obj .: "to" <*> obj .: "why"
    "refused" -> Refused <$> (Note <$> obj .: "message" <*> obj .: "fix")
    "asked" -> Asked <$> askingOf obj
    "retagged" -> RetaggedSecurity <$> qidOf obj <* (obj .: "kind" >>= security)
    "ruled" ->
        RuledOn
            <$> qidOf obj
            <*> ( Proposal
                    <$> oneLineAt "answer" obj
                    <*> oneLineAt "why" obj
                    <*> oneLineAt "cost" obj
                    <*> (obj .: "basis" >>= traverse basisOf)
                )
    "forwarded" -> Forwarded <$> qidOf obj <*> (obj .: "to" >>= aboveOf)
    "answered" -> Answered <$> qidOf obj <*> replyOf obj <*> (obj .: "by" >>= aboveOf)
    "parked" -> QuestionParked <$> qidOf obj <*> oneLineAt "why" obj
    "spawned" ->
        Spawned
            <$> ( Child
                    <$> childOf obj
                    <*> ( childTaskOf obj
                            >>= maybe (fail "a spawned child names its task or is untasked") pure
                        )
                    <*> obj .: "worktree"
                )
    "spawning" -> Spawning <$> taskOf obj
    "resumed" -> Resumed <$> childOf obj
    "handed_back" -> HandedBack <$> childOf obj <*> saidOf obj
    "task" -> TaskMoved <$> taskOf obj <*> taskStateOf obj
    "held" -> Held <$> taskOf obj <*> urlOf obj
    "acted" -> ActedOn <$> taskOf obj <*> urlOf obj
    "task_added" -> TaskAdded <$> (obj .: "task" >>= Artifact.taskOf)
    "restarted" -> pure Restarted
    "worker_handed_back" -> WorkerHandedBack . AgentRole <$> obj .: "role" <*> oneLineAt "line" obj
    "worker_spawned" -> WorkerSpawned . AgentRole <$> obj .: "role" <*> (AgentId <$> obj .: "agent")
    "worker_returned" ->
        WorkerReturned . AgentRole
            <$> obj .: "role"
            <*> (fmap AgentId <$> obj .: "agent")
    "agent_ended" -> AgentEnded . AgentId <$> obj .: "agent"
    "suspended" -> Suspended <$> requestOf obj <*> oneLineAt "summary" obj
    "focused" -> Focused <$> requestOf obj
    "voided" -> Voided <$> obj .: "seq" <*> obj .: "why"
    _ -> case Map.lookup step outcomeParsers of
        Just parser -> Took scope <$> parser obj
        Nothing -> fail ("unknown event type " <> show kind)
  where
    (scope, step) = unqualify kind

{- | Keyed by the event names the layers give each outcome, so a renamed
outcome changes the wire with it. A step inside a scope logs its outcome
under the qualified name, @security/review.rows@.
-}
outcomeParsers :: Map Text (Object -> Parser AnyOutcome)
outcomeParsers = Map.fromList (map (first eventText) (outcomeDecoders <> drawnDecoders))

childOf :: Object -> Parser RunId
childOf obj = obj .: "child" >>= runIdOf

requestOf :: Object -> Parser TaskNo
requestOf obj =
    obj .: "request" >>= \raw -> maybe (fail (show raw <> " is no request, r<n>")) pure (parseTaskNo raw)

taskOf :: Object -> Parser TaskId
taskOf obj = TaskId <$> obj .: "task"

-- | A fan-out's child names its task, or says it has none.
childTaskData :: ChildTask -> Series
childTaskData = \case
    Tasked task -> "task" .= taskIdText task
    Untasked -> "untasked" .= True

-- | A fan-out's child as 'childTaskData' writes it; neither key, no fan-out's child.
childTaskOf :: Object -> Parser (Maybe ChildTask)
childTaskOf obj =
    (,) <$> obj .:? "task" <*> obj .:? "untasked" <&> \case
        (Just task, _) -> Just (Tasked (TaskId task))
        (Nothing, Just True) -> Just Untasked
        (Nothing, _) -> Nothing

{- | #360's @token@, @ref@ and @qid@: the hand-back's line 1 as the child
sent it, a stop's as 'stopWire' spells it.
-}
saidData :: Said -> Series
saidData said = "token" .= token <> "ref" .= ref <> "qid" .= fmap qidText qid <> waits
  where
    (token, ref, qid) = case said of
        Finished summary -> ("READY", Just (oneLineText summary), Nothing)
        AsksUp asked -> ("NEEDS_DECISION", Nothing, Just asked)
        Awaits _ on -> ("AWAIT", Just (oneLineText on), Nothing)
        Ended stop -> let (word, payload) = stopWire stop in (word, Just payload, Nothing)
    -- Only a merge is named: a log from before merges climbed awaits CI.
    waits = case said of
        Awaits Merge _ -> "on" .= waitingText Merge
        Awaits Ci _ -> mempty
        Finished _ -> mempty
        AsksUp _ -> mempty
        Ended _ -> mempty

saidOf :: Object -> Parser Said
saidOf obj =
    obj .: "token" >>= \case
        "READY" -> Finished <$> oneLineAt "ref" obj
        "AWAIT" ->
            Awaits
                <$> (obj .:? "on" >>= maybe (pure Ci) (named "awaited" (parseByName waitingText)))
                <*> oneLineAt "ref" obj
        token ->
            obj .:? "ref" >>= \case
                Nothing | token == "NEEDS_DECISION" -> AsksUp <$> qidOf obj
                ref ->
                    maybe
                        (fail ("no hand-back token: " <> show token))
                        (pure . Ended)
                        (parseStop token (fromMaybe "" ref))

{- | A stop on the wire (#360): its hand-back token, and the prefix its why
takes there. The one spelling of a stop, read by the log and the hand-back.
-}
stopToken :: StopReason -> (Text, Text)
stopToken = \case
    Blocked -> ("BLOCKED", "")
    Failed -> ("FAILED", "")
    Replan -> ("NEEDS_DECISION", "plan wrong: ")
    OutOfRounds -> ("BLOCKED", "out of rounds: ")

-- | A stop's hand-back token and its payload.
stopWire :: Stop -> (Text, Text)
stopWire stop = (word, prefix <> stop.why)
  where
    (word, prefix) = stopToken stop.reason

-- | The stop a hand-back's line 1 says, if it says one.
parseStopLine :: Text -> Maybe Stop
parseStopLine line = parseStop word (Text.drop 1 payload)
  where
    (word, payload) = Text.breakOn " " line

{- | The prefixed reasons are tried first, so @BLOCKED out of rounds: x@ reads as
'OutOfRounds', as the wire cannot tell it from a 'Blocked' whose why says so.
-}
parseStop :: Text -> Text -> Maybe Stop
parseStop token payload =
    listToMaybe
        [ Stop reason why
        | reason <- sortOn (Text.null . snd . stopToken) [minBound .. maxBound]
        , let (word, prefix) = stopToken reason
        , word == token
        , Just why <- [Text.stripPrefix prefix payload]
        ]

taskStateData :: TaskState -> Series
taskStateData moved = "state" .= taskStateName moved <> "why" .= why <> "pr" .= fmap urlText pr
  where
    (why, pr) = case moved of
        InCi url -> (Nothing, Just url)
        InReview url -> (Nothing, Just url)
        Merged url -> (Nothing, Just url)
        Kept url -> (Nothing, Just url)
        Round url -> (Nothing, Just url)
        Parked reason parkedPr -> (Just reason, parkedPr)

taskStateOf :: Object -> Parser TaskState
taskStateOf obj = do
    pr <- fmap Url <$> obj .: "pr"
    name <- obj .: "state"
    case (lookup name prStates, name) of
        (Just state, _) ->
            maybe
                (fail ("a task in " <> Text.unpack name <> " names its pr"))
                (pure . state)
                pr
        (Nothing, "parked") -> Parked <$> obj .: "why" <*> pure pr
        (Nothing, other) -> fail ("unknown task state " <> show other)

-- | The states that name their PR, by the name 'taskStateName' gives each: @state record task@'s and the log's.
prStates :: [(Text, Url -> TaskState)]
prStates =
    [ ("ci", InCi)
    , ("review", InReview)
    , ("merged", Merged)
    , ("kept", Kept)
    , ("round", Round)
    ]

-- | As @state record task@ names it.
taskStateName :: TaskState -> Text
taskStateName = \case
    InCi _ -> "ci"
    InReview _ -> "review"
    Merged _ -> "merged"
    Kept _ -> "kept"
    Round _ -> "round"
    Parked _ _ -> "parked"

-- | The arguments @state record task@ takes after the task's id for this state.
taskStateArgs :: TaskState -> Text
taskStateArgs moved =
    Text.unwords $
        taskStateName moved : case moved of
            InCi pr -> [urlText pr]
            InReview pr -> [urlText pr]
            Merged pr -> [urlText pr]
            Kept pr -> [urlText pr]
            Round pr -> [urlText pr]
            Parked why pr -> why : maybe [] (\url -> ["--pr", urlText url]) pr

startOf :: Object -> Parser Start
startOf obj =
    Start
        <$> (obj .: "flow" >>= named "flow" (parseByName flowText))
        <*> obj .: "notes"
        <*> (obj .: "principal" >>= principalOf)
        <*> ( Set.fromList
                <$> (obj .: "interface" >>= traverse (named "operation" (parseByName opText)))
            )

{- | The user on its own PR is a bare word, as a log older than rounds wrote
it; the user's round is its PR; a parent run is its id, the task it
gave a fan-out's child, a round's PR and a decided plan; the caller is the user's form marked
@caller@.
-}
principalEncoding :: Principal -> Encoding
principalEncoding = \case
    ByUser OwnPr -> text "user"
    ByUser shape@(RoundOn _) -> pairs (shapeData shape)
    ByRole parent shape plan ->
        pairs
            ( "run" .= runIdText parent.run
                <> linkData parent.link
                <> shapeData shape
                <> planData plan
            )
    ByCaller OwnPr -> text "caller"
    ByCaller shape@(RoundOn _) -> pairs ("caller" .= True <> shapeData shape)

principalOf :: Value -> Parser Principal
principalOf = \case
    String "user" -> pure (ByUser OwnPr)
    String "caller" -> pure (ByCaller OwnPr)
    Object obj ->
        (,) <$> obj .:? "run" <*> obj .:? "caller" >>= \case
            (Just run, _) ->
                ByRole
                    <$> (Parent <$> runIdOf run <*> linkOf obj)
                    <*> shapeOf obj
                    <*> planOf obj
            (Nothing, Just True) -> ByCaller . RoundOn . Url <$> obj .: "pr"
            (Nothing, _) -> ByUser . RoundOn . Url <$> obj .: "pr"
    other ->
        fail
            ( "a principal is \"user\", \"caller\", {pr}, {caller, pr} or {run, task?}, not "
                <> show other
            )

-- | A fan-out's child names its task or its delegation; a direct child, neither.
linkData :: Link -> Series
linkData = \case
    InFan task -> childTaskData task
    Direct -> mempty

linkOf :: Object -> Parser Link
linkOf obj = maybe Direct InFan <$> childTaskOf obj

askingOf :: Object -> Parser Asking
askingOf obj = do
    qid <- qidOf obj
    kind <- obj .: "kind" >>= named "kind" parseKind
    question <- oneLineAt "question" obj
    step <- StateName <$> obj .: "step"
    from <- obj .: "from" >>= askerOf
    pure Asking {question = Question qid kind question, step, from}

qidOf :: Object -> Parser QId
qidOf obj = obj .: "qid" >>= named "question id" parseQId

-- | A retag to any other kind is refused: no event lowers a 'Security' question.
security :: Text -> Parser ()
security raw
    | raw == kindName Security = pure ()
    | otherwise =
        fail ("a question is only ever re-tagged as Security, not " <> show raw)

-- | The run itself is a bare word; a subagent is its role, a child run its id.
askerEncoding :: Asker -> Encoding
askerEncoding = \case
    Itself -> text "self"
    Subagent (AgentRole role) -> pairs ("role" .= role)
    ChildRun run -> pairs ("run" .= runIdText run)

askerOf :: Value -> Parser Asker
askerOf = \case
    String "self" -> pure Itself
    Object obj ->
        obj .:? "role"
            >>= maybe (ChildRun <$> (obj .: "run" >>= runIdOf)) (pure . Subagent . AgentRole)
    other -> fail ("a question is from \"self\", {role} or {run}, not " <> show other)

-- | As a principal: the user and the caller are bare words, a parent run is its id.
aboveEncoding :: Above -> Encoding
aboveEncoding = \case
    TheUser -> text "user"
    ParentRun run -> pairs ("run" .= runIdText run)
    TheCaller -> text "caller"

-- | @"reply": "chose"@ or @"other"@, beside the @answer@ text.
replyData :: Reply -> Series
replyData = \case
    Chose answer -> "reply" .= ("chose" :: Text) <> "answer" .= answer
    Other answer -> "reply" .= ("other" :: Text) <> "answer" .= answer

replyOf :: Object -> Parser Reply
replyOf obj =
    obj .: "reply" >>= \case
        "chose" -> Chose <$> obj .: "answer"
        "other" -> Other <$> obj .: "answer"
        other -> fail ("reply \"chose\" or \"other\", not " <> show (other :: Text))

aboveOf :: Value -> Parser Above
aboveOf = \case
    String "user" -> pure TheUser
    String "caller" -> pure TheCaller
    Object obj -> ParentRun <$> (obj .: "run" >>= runIdOf)
    other -> fail ("\"user\", \"caller\" or {run}, not " <> show other)

basisEncoding :: Basis -> Encoding
basisEncoding = \case
    AnsweredBy event -> pairs ("event" .= eventIdText event)
    Obvious why -> pairs ("obvious" .= oneLineText why)

basisOf :: Value -> Parser Basis
basisOf = withObject "basis" $ \obj ->
    obj .:? "obvious" >>= \case
        Just why -> Obvious <$> oneLineOf why
        Nothing -> AnsweredBy <$> (obj .: "event" >>= named "event id" parseEventId)

oneLineAt :: Key -> Object -> Parser OneLine
oneLineAt key obj = obj .: key >>= oneLineOf

oneLineOf :: Text -> Parser OneLine
oneLineOf raw = maybe (fail (show raw <> " holds a line break")) pure (parseOneLine raw)

runIdOf :: Text -> Parser RunId
runIdOf raw =
    maybe
        (fail ("run id " <> show raw <> " is empty, h, or holds a colon or a line break"))
        pure
        (parseRunId raw)

-- | #360's @AWAIT <what> <refs>@: what a run hands up to be waited on.
waitingText :: Waiting -> Text
waitingText = \case
    Ci -> "ci"
    Merge -> "merge"

opText :: Op -> Text
opText = \case
    AskUser -> "ask_user"
    Await -> "await"
    Notify -> "notify"
    Hooks -> "hooks"
    Background -> "background"

reasonText :: StopReason -> Text
reasonText = \case
    Blocked -> "blocked"
    Failed -> "failed"
    Replan -> "replan"
    OutOfRounds -> "rounds"
