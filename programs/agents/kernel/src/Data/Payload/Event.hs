{- | An envelope as an @events@ row and back, the @runs@ row its first
event makes, and the payload's JSON: one I-JSON object (RFC 7493) per event,
its keys by type. Every union is an object tagged by its @kind@ key (RFC
8927's discriminator); an enum is lowercase snake_case; an optional key is
left out, never null. The columns are "Data.Field"'s.
-}
module Data.Payload.Event (
    eventRow,
    runRow,
    Decoded (..),
    RetiredEvent (..),
    UnknownEvent (..),
    decodeRow,
    dumpLine,
    questionKindName,
    taskStateKind,
) where

import Data.Aeson (
    Key,
    Object,
    Value,
    eitherDecodeStrictText,
    withObject,
    (.:),
    (.:?),
    (.=),
 )
import Data.Aeson.Encoding (
    Encoding,
    encodingToLazyByteString,
    pair,
    pairs,
    unsafeToEncoding,
 )
import Data.Aeson.Types (Parser, Series, parseEither)
import Data.Bifunctor (first)
import Data.Entity.Event (EventRow (..))
import Data.Entity.Run (RunRow (..))
import Data.Field qualified as Field
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Payload.Upcast (Upcasts (..), typeOf)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.Lazy qualified as Lazy
import Data.Text.Lazy.Encoding qualified as Lazy
import Numeric.Natural (Natural)
import State.Category.Flow (unqualify)
import State.Category.Fuel (parseByName)
import State.Category.Step (eventText)
import State.Role (drawnDecoders, flowText)
import State.Run.Ask (
    Above (..),
    Basis (..),
    Kind (..),
    OneLine,
    Proposal (..),
    QId,
    Question (..),
    oneLineText,
    parseOneLine,
    parseQId,
    qidText,
 )
import State.Run.Codec (eventType, reasonText, waitingText)
import State.Run.Event (
    AgentId (..),
    AgentRole (..),
    AnyOutcome,
    Asker (..),
    Asking (..),
    Child (..),
    ChildTask (..),
    Digest,
    Envelope (..),
    Event (..),
    Link (..),
    Note (..),
    Op (..),
    Parent (..),
    Principal (..),
    Reply (..),
    RunId,
    Said (..),
    Source (..),
    Start (..),
    StateName (..),
    Stop (..),
    TaskId (..),
    TaskNo,
    TaskState (..),
    Url (..),
    parseRunId,
    parseTaskNo,
    runIdText,
    taskNoText,
 )
import State.Run.Id (eventIdText, parseEventId)
import State.Step.Artifact (
    named,
    planData,
    planOf,
    shapeData,
    shapeOf,
    targetData,
    targetOf,
    taskEncoding,
    taskIdText,
    unknownCase,
    urlData,
    urlOf,
    urlText,
 )
import State.Step.Artifact qualified as Artifact
import State.Step.Catalog (outcomeData, outcomeDecoders)

eventRow :: Envelope -> EventRow
eventRow e =
    EventRow
        { runId = Field.encode Field.runId e.run
        , seq = fromIntegral e.seq
        , schemaVersion = fromIntegral schemaVersion
        , eventType = eventType e.event
        , time = Field.encode Field.time e.ts
        , sessionId = Field.encode Field.session <$> e.session
        , headSha = Field.encode Field.sha <$> e.head
        , hookDigest = case e.source of
            Cli -> Nothing
            Hook digest -> Just (Field.encode Field.digest digest)
        , payload = payloadText e.event
        }

{- | The run's @runs@ row, when this is its first event, @started@: a pure
function of it, so the index cannot say what the log does not.
-}
runRow :: Envelope -> Maybe RunRow
runRow e = case e of
    Envelope {seq = 1, event = Started start} ->
        Just
            RunRow
                { id = Field.encode Field.runId e.run
                , parentRunId = Field.encode Field.runId <$> parentOf start.principal
                , flow = flowText start.flow
                , notesDir = Text.pack start.notes
                , createdAt = Field.encode Field.time e.ts
                }
    Envelope {} -> Nothing
  where
    parentOf = \case
        ByRole parent _ _ -> Just parent.run
        ByUser _ -> Nothing
        ByCaller _ -> Nothing

{- | What a row reads as. Total: every row is one of these, so dump, reports
and SQL read any row, while an append refuses a run holding an 'Unknown'.
-}
data Decoded
    = Known Envelope
    | -- | A type that left the domain: the fold skips it.
      Retired RetiredEvent
    | {- | A row this kernel cannot read: an unknown type, another payload
      version, or a column or payload that does not fit.
      -}
      Unknown UnknownEvent
    deriving stock (Eq, Show)

data RetiredEvent = RetiredEvent
    { eventType :: Text
    , payload :: Text
    , digest :: Maybe Digest
    {- ^ The hook's record it was, if a hook wrote it: still seen, so the
    hook fired again appends nothing.
    -}
    }
    deriving stock (Eq, Show)

data UnknownEvent = UnknownEvent
    {eventType :: Text, schemaVersion :: Int64, payload :: Text}
    deriving stock (Eq, Show)

{- | The row read through these upcasts: its type renamed by the alias table
first, then retired, read, or not readable.
-}
decodeRow :: Upcasts -> EventRow -> Decoded
decodeRow upcasts row
    | Set.member kind upcasts.retired =
        maybe unknown Retired $ do
            digest <- hookDigest
            pure RetiredEvent {eventType = kind, payload = row.payload, digest}
    | row.schemaVersion /= fromIntegral schemaVersion = unknown
    | otherwise = maybe unknown Known $ do
        run <- Field.decode Field.runId row.runId
        n <- Field.natural row.seq
        ts <- Field.decode Field.time row.time
        session <- traverse (Field.decode Field.session) row.sessionId
        sha <- traverse (Field.decode Field.sha) row.headSha
        source <- maybe Cli Hook <$> hookDigest
        event <- either (const Nothing) Just (decodePayload kind row.payload)
        pure Envelope {source, seq = n, ts, run, head = sha, session, event}
  where
    kind = typeOf upcasts row.eventType
    -- Nothing when the column holds text that is no digest.
    hookDigest = traverse (Field.decode Field.digest) row.hookDigest
    unknown =
        Unknown
            UnknownEvent
                { eventType = row.eventType
                , schemaVersion = row.schemaVersion
                , payload = row.payload
                }

{- | The row as one JSON Lines line (jsonlines.org), without its newline:
every column a key in the table's order, @null@ for NULL, and @data@ spliced
verbatim from its text, a JSON object by the table's CHECK, so a duplicate
key or the key order survives. @position@, the store's own order across
runs, is left out: a run's order is its seq.
-}
dumpLine :: EventRow -> Text
dumpLine row =
    Lazy.toStrict . Lazy.decodeUtf8 . encodingToLazyByteString . pairs $
        "run_id" .= row.runId
            <> "seq" .= row.seq
            <> "schema_version" .= row.schemaVersion
            <> "type" .= row.eventType
            <> "time" .= row.time
            <> "session_id" .= row.sessionId
            <> "head_sha" .= row.headSha
            <> "hook_digest" .= row.hookDigest
            <> pair "data" (unsafeToEncoding (Text.encodeUtf8Builder row.payload))

{- | The payload version every event type has in the store, from 1: a
change of one type's shape bumps that type's.
-}
schemaVersion :: Int
schemaVersion = 1

-- | An event's payload, the store's @data@: one JSON object, its keys by type.
payloadText :: Event -> Text
payloadText =
    Lazy.toStrict . Lazy.decodeUtf8 . encodingToLazyByteString . pairs . eventData

{- | The event of this type whose payload this is, or why it does not read.
A key no case names is ignored (RFC 7493 s4.2, Must-Ignore).
-}
decodePayload :: Text -> Text -> Either Text Event
decodePayload kind raw =
    first
        Text.pack
        (eitherDecodeStrictText raw >>= parseEither (withObject "data" (eventOf kind)))

eventData :: Event -> Series
eventData = \case
    Started start ->
        "flow" .= flowText start.flow
            <> "notes_dir" .= start.notes
            <> pair "principal" (principalEncoding start.principal)
            <> "interface" .= map opText (Set.toList start.interface)
    Targeted target -> targetData target
    Extended why -> "reason" .= why
    Gapped gap -> "text" .= gap
    Took _ outcome -> outcomeData outcome
    Stopped stop -> stopData stop
    Overridden (StateName to) why -> "to" .= to <> "reason" .= why
    Refused note -> "message" .= note.message <> "fix" .= note.fix
    Asked Asking {question, step = StateName step, from} ->
        qidData question.qid
            <> "question_kind" .= questionKindName question.kind
            <> "question" .= oneLineText question.text
            <> "step" .= step
            <> pair "from" (askerEncoding from)
    -- #360 writes the kind, though it is only ever Security.
    RetaggedSecurity qid -> qidData qid <> "question_kind" .= questionKindName Security
    RuledOn qid proposal ->
        qidData qid
            <> "answer" .= oneLineText proposal.answer
            <> "reason" .= oneLineText proposal.why
            <> "cost" .= oneLineText proposal.cost
            <> pair "basis" (basisEncoding proposal.basis)
    Forwarded qid to -> qidData qid <> pair "to" (partyEncoding to)
    Answered qid reply by -> qidData qid <> replyData reply <> pair "by" (partyEncoding by)
    QuestionParked qid why -> qidData qid <> "reason" .= oneLineText why
    Spawned child -> spawnedData child
    Spawning task -> "task" .= taskIdText task
    Resumed child -> "child" .= runIdText child
    HandedBack child said -> "child" .= runIdText child <> saidData said
    TaskMoved task moved -> "task" .= taskIdText task <> pair "state" (taskStateEncoding moved)
    Held task url -> "task" .= taskIdText task <> urlData url
    ActedOn task url -> "task" .= taskIdText task <> urlData url
    TaskAdded task -> pair "task" (taskEncoding task)
    Restarted -> mempty
    WorkerHandedBack (AgentRole role) line -> "role" .= role <> "line" .= oneLineText line
    WorkerSpawned (AgentRole role) agent -> "role" .= role <> "agent" .= agent.agentIdText
    WorkerReturned (AgentRole role) agent -> "role" .= role <> foldMap (("agent" .=) . (.agentIdText)) agent
    AgentEnded agent -> "agent" .= agent.agentIdText
    Suspended task summary -> "request" .= taskNoText task <> "summary" .= oneLineText summary
    Focused task -> "request" .= taskNoText task
    Voided n why -> "seq" .= n <> "reason" .= why
  where
    qidData qid = "qid" .= qidText qid

eventOf :: Text -> Object -> Parser Event
eventOf kind obj = case kind of
    "started" -> Started <$> startOf obj
    "target" -> Targeted <$> targetOf obj
    "extend" -> Extended <$> obj .: "reason"
    "gap" -> Gapped <$> obj .: "text"
    "stop" -> Stopped <$> stopOf obj
    "overridden" -> Overridden . StateName <$> obj .: "to" <*> obj .: "reason"
    "refused" -> Refused <$> (Note <$> obj .: "message" <*> obj .: "fix")
    "asked" -> Asked <$> askingOf obj
    "retagged" -> RetaggedSecurity <$> qidOf obj <* (obj .: "question_kind" >>= security)
    "ruled" ->
        RuledOn
            <$> qidOf obj
            <*> ( Proposal
                    <$> oneLineAt "answer" obj
                    <*> oneLineAt "reason" obj
                    <*> oneLineAt "cost" obj
                    <*> (obj .: "basis" >>= basisOf)
                )
    "forwarded" -> Forwarded <$> qidOf obj <*> (obj .: "to" >>= partyOf)
    "answered" -> Answered <$> qidOf obj <*> replyOf obj <*> (obj .: "by" >>= partyOf)
    "parked" -> QuestionParked <$> qidOf obj <*> oneLineAt "reason" obj
    "spawned" -> Spawned <$> spawnedOf obj
    "spawning" -> Spawning <$> taskOf obj
    "resumed" -> Resumed <$> childOf obj
    "handed_back" -> HandedBack <$> childOf obj <*> saidOf obj
    "task" -> TaskMoved <$> taskOf obj <*> (obj .: "state" >>= taskStateOf)
    "held" -> Held <$> taskOf obj <*> urlOf obj
    "acted" -> ActedOn <$> taskOf obj <*> urlOf obj
    "task_added" -> TaskAdded <$> (obj .: "task" >>= Artifact.taskOf)
    "restarted" -> pure Restarted
    "worker_handed_back" -> WorkerHandedBack . AgentRole <$> obj .: "role" <*> oneLineAt "line" obj
    "worker_spawned" -> WorkerSpawned . AgentRole <$> obj .: "role" <*> (AgentId <$> obj .: "agent")
    "worker_returned" ->
        WorkerReturned . AgentRole
            <$> obj .: "role"
            <*> (fmap AgentId <$> obj .:? "agent")
    "agent_ended" -> AgentEnded . AgentId <$> obj .: "agent"
    "suspended" -> Suspended <$> requestOf obj <*> oneLineAt "summary" obj
    "focused" -> Focused <$> requestOf obj
    "voided" -> Voided <$> (obj .: "seq" >>= ijsonNatural) <*> obj .: "reason"
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

-- | A question's kind as the log spells it; the CLI's is 'State.Run.Ask.kindName'.
questionKindName :: Kind -> Text
questionKindName = \case
    Fact -> "fact"
    Pick -> "pick"
    Design -> "design"
    Scope -> "scope"
    Confirm -> "confirm"
    Security -> "security"
    Stuck -> "stuck"

-- | A task state's @kind@ in the log; the CLI's name is 'State.Run.Codec.taskStateName'.
taskStateKind :: TaskState -> Text
taskStateKind = \case
    InCi _ -> "in_ci"
    InReview _ -> "in_review"
    Merged _ -> "merged"
    Kept _ -> "kept"
    Round _ -> "round"
    Parked _ _ -> "parked"

{- | An I-JSON integer (RFC 7493 s2.2): under 2^53, so every JSON reader
reads it exactly. One at or above does not fit, so its row reads as
'Unknown'. The bound is sound for a voided seq: @appendTo@
("State.Run.Fold") logs a void only of a seq the run already logged, and no
run logs 2^53 events.
-}
ijsonNatural :: Natural -> Parser Natural
ijsonNatural n
    | n < 2 ^ (53 :: Int) = pure n
    | otherwise = fail (show n <> " is no I-JSON integer: it is 2^53 or more")

-- | A union's tag, RFC 8927's discriminator: the one key named @kind@.
tag :: Text -> Series
tag = ("kind" .=)

-- | The case of a union by its @kind@: each case reads the object's other keys.
tagged :: String -> (Object -> Text -> Parser a) -> Value -> Parser a
tagged what caseOf = withObject what (\obj -> obj .: "kind" >>= caseOf obj)

-- | A stop, and a child's hand-back that ended so: its reason and its detail.
stopData :: Stop -> Series
stopData stop = "reason" .= reasonText stop.reason <> "detail" .= stop.why

stopOf :: Object -> Parser Stop
stopOf obj =
    Stop
        <$> (obj .: "reason" >>= named "stop reason" (parseByName reasonText))
        <*> obj .: "detail"

childOf :: Object -> Parser RunId
childOf obj = obj .: "child" >>= runIdOf

requestOf :: Object -> Parser TaskNo
requestOf obj =
    obj .: "request" >>= \raw -> maybe (fail (show raw <> " is no request, r<n>")) pure (parseTaskNo raw)

taskOf :: Object -> Parser TaskId
taskOf obj = TaskId <$> obj .: "task"

-- | The event is the union: @kind: tasked@ names the child's task, @untasked@ none.
spawnedData :: Child -> Series
spawnedData child = case child.task of
    Tasked task -> tag "tasked" <> common <> "task" .= taskIdText task
    Untasked -> tag "untasked" <> common
  where
    common = "child" .= runIdText child.run <> "worktree" .= child.worktree

spawnedOf :: Object -> Parser Child
spawnedOf obj =
    Child
        <$> childOf obj
        <*> ( obj .: "kind" >>= \case
                "tasked" -> Tasked <$> taskOf obj
                "untasked" -> pure Untasked
                other -> unknownCase "spawned kind" other
            )
        <*> obj .: "worktree"

-- | The event is the union, by how the child's hand-back ended its work.
saidData :: Said -> Series
saidData = \case
    Finished summary -> tag "finished" <> "summary" .= oneLineText summary
    AsksUp qid -> tag "asks_up" <> "qid" .= qidText qid
    Awaits on summary -> tag "awaits" <> "on" .= waitingText on <> "summary" .= oneLineText summary
    Ended stop -> tag "ended" <> stopData stop

saidOf :: Object -> Parser Said
saidOf obj =
    obj .: "kind" >>= \case
        "finished" -> Finished <$> oneLineAt "summary" obj
        "asks_up" -> AsksUp <$> qidOf obj
        "awaits" ->
            Awaits
                <$> (obj .: "on" >>= named "awaited" (parseByName waitingText))
                <*> oneLineAt "summary" obj
        "ended" -> Ended <$> stopOf obj
        other -> unknownCase "hand-back kind" other

taskStateEncoding :: TaskState -> Encoding
taskStateEncoding moved =
    pairs . (tag (taskStateKind moved) <>) $ case moved of
        InCi url -> prUrl url
        InReview url -> prUrl url
        Merged url -> prUrl url
        Kept url -> prUrl url
        Round url -> prUrl url
        Parked why pr -> "reason" .= why <> foldMap prUrl pr
  where
    prUrl url = "pr_url" .= urlText url

taskStateOf :: Value -> Parser TaskState
taskStateOf = tagged "task state" $ \obj -> \case
    "in_ci" -> InCi <$> prUrlOf obj
    "in_review" -> InReview <$> prUrlOf obj
    "merged" -> Merged <$> prUrlOf obj
    "kept" -> Kept <$> prUrlOf obj
    "round" -> Round <$> prUrlOf obj
    "parked" -> Parked <$> obj .: "reason" <*> (fmap Url <$> obj .:? "pr_url")
    other -> unknownCase "task state" other
  where
    prUrlOf obj = Url <$> obj .: "pr_url"

startOf :: Object -> Parser Start
startOf obj =
    Start
        <$> (obj .: "flow" >>= named "flow" (parseByName flowText))
        <*> obj .: "notes_dir"
        <*> (obj .: "principal" >>= principalOf)
        <*> ( Set.fromList
                <$> (obj .: "interface" >>= traverse (named "operation" (parseByName opText)))
            )

-- | Who started the run, and for a parent run how it links the child and settles its plan.
principalEncoding :: Principal -> Encoding
principalEncoding =
    pairs . \case
        ByUser shape -> tag "user" <> shapeData shape
        ByRole parent shape plan ->
            tag "parent_run"
                <> "run" .= runIdText parent.run
                <> pair "link" (linkEncoding parent.link)
                <> shapeData shape
                <> planData plan
        ByCaller shape -> tag "caller" <> shapeData shape

principalOf :: Value -> Parser Principal
principalOf = tagged "principal" $ \obj -> \case
    "user" -> ByUser <$> shapeOf obj
    "parent_run" ->
        ByRole
            <$> (Parent <$> (obj .: "run" >>= runIdOf) <*> (obj .: "link" >>= linkOf))
            <*> shapeOf obj
            <*> planOf obj
    "caller" -> ByCaller <$> shapeOf obj
    other -> unknownCase "principal" other

-- | A fan-out's child names its task, or says it has none; a direct child is direct.
linkEncoding :: Link -> Encoding
linkEncoding =
    pairs . \case
        InFan (Tasked task) -> tag "task" <> "task" .= taskIdText task
        InFan Untasked -> tag "untasked"
        Direct -> tag "direct"

linkOf :: Value -> Parser Link
linkOf = tagged "link" $ \obj -> \case
    "task" -> InFan . Tasked <$> taskOf obj
    "untasked" -> pure (InFan Untasked)
    "direct" -> pure Direct
    other -> unknownCase "link" other

askingOf :: Object -> Parser Asking
askingOf obj = do
    qid <- qidOf obj
    kind <-
        obj .: "question_kind" >>= named "question kind" (parseByName questionKindName)
    question <- oneLineAt "question" obj
    step <- StateName <$> obj .: "step"
    from <- obj .: "from" >>= askerOf
    pure Asking {question = Question qid kind question, step, from}

qidOf :: Object -> Parser QId
qidOf obj = obj .: "qid" >>= named "question id" parseQId

-- | A retag to any other kind is refused: no event lowers a 'Security' question.
security :: Text -> Parser ()
security raw
    | raw == questionKindName Security = pure ()
    | otherwise =
        fail ("a question is only ever re-tagged as security, not " <> show raw)

askerEncoding :: Asker -> Encoding
askerEncoding =
    pairs . \case
        Itself -> tag "self"
        Subagent (AgentRole role) -> tag "subagent" <> "role" .= role
        ChildRun run -> tag "child_run" <> "run" .= runIdText run

askerOf :: Value -> Parser Asker
askerOf = tagged "asker" $ \obj -> \case
    "self" -> pure Itself
    "subagent" -> Subagent . AgentRole <$> obj .: "role"
    "child_run" -> ChildRun <$> (obj .: "run" >>= runIdOf)
    other -> unknownCase "asker" other

-- | Who a question goes to, or who answered it.
partyEncoding :: Above -> Encoding
partyEncoding =
    pairs . \case
        TheUser -> tag "user"
        ParentRun run -> tag "parent_run" <> "run" .= runIdText run
        TheCaller -> tag "caller"

partyOf :: Value -> Parser Above
partyOf = tagged "party" $ \obj -> \case
    "user" -> pure TheUser
    "parent_run" -> ParentRun <$> (obj .: "run" >>= runIdOf)
    "caller" -> pure TheCaller
    other -> unknownCase "party" other

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

-- | A ruling with no basis is @{kind: none}@, never null.
basisEncoding :: Maybe Basis -> Encoding
basisEncoding =
    pairs . \case
        Nothing -> tag "none"
        Just (AnsweredBy event) -> tag "event" <> "event" .= eventIdText event
        Just (Obvious why) -> tag "obvious" <> "reason" .= oneLineText why

basisOf :: Value -> Parser (Maybe Basis)
basisOf = tagged "basis" $ \obj -> \case
    "none" -> pure Nothing
    "event" -> Just . AnsweredBy <$> (obj .: "event" >>= named "event id" parseEventId)
    "obvious" -> Just . Obvious <$> oneLineAt "reason" obj
    other -> unknownCase "basis" other

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

opText :: Op -> Text
opText = \case
    AskUser -> "ask_user"
    Await -> "await"
    Notify -> "notify"
    Hooks -> "hooks"
    Background -> "background"
