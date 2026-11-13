{- | The log on the wire: one JSON object per line, version 3.

> {"v":3,"id":"r7f2:12","seq":12,"ts":"...","run":"r7f2","head":"abc123",
>  "session":null,"type":"review.rows","data":{"head":"abc123"}}

A step event's @type@ is its edge's name in the flow's graph. A log the
Python @state@ wrote (versions 1 and 2, no @v@ on the line) is refused, not
read: the rewrite breaks it on purpose.
-}
module State.Run.Codec (
    version,
    logName,
    logOf,
    encodeLine,
    decodeLine,
    decodeLog,
    decodeLogBytes,
    encodeLines,
    firstLineBytes,
    firstLineOf,
    LineError (..),
    LogError (..),
    eventType,
    areaText,
    reasonText,
    stopToken,
    stopWire,
    parseStopLine,
    judgementText,
    flowText,
    opText,
    shaText,
    urlText,
    taskIdText,
    branchText,
    taskStateName,
    taskStateArgs,
    prStates,
    topicText,
    decodeBreakdown,
) where

import Data.Aeson (Key, Object, Value (..), eitherDecodeStrictText, withObject, (.:), (.:?), (.=))
import Data.Aeson.Encoding (Encoding, encodingToLazyByteString, null_, pair, pairs, text)
import Data.Aeson.Types (Parser, Series, parseEither)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8', decodeUtf8Lenient, encodeUtf8)
import Data.Text.Lazy qualified as Lazy
import Data.Text.Lazy.Encoding qualified as Lazy
import Numeric.Natural (Natural)
import State.Category.Mode (parseByName, parseQuality, qualityName, sizeName)
import State.Category.Step (eventText)
import State.Role (RoleDef (..), roleText)
import State.Role qualified as Role
import State.Run.Ask (Above (..), Basis (..), Kind (Security), OneLine, Proposal (..), QId, Question (..), kindName, oneLineText, parseKind, parseOneLine, parseQId, qidText)
import State.Run.Event (
    AgentRole (..),
    AnyOutcome,
    Asker (..),
    Asking (..),
    Child (..),
    Envelope (..),
    Event (..),
    EventId (..),
    FlowName (..),
    Note (..),
    Op (..),
    Parent (..),
    Principal (..),
    RunId,
    Said (..),
    SessionId (..),
    Sha (..),
    Source (..),
    Start (..),
    StateName (..),
    Stop (..),
    StopReason (..),
    TaskId (..),
    TaskState (..),
    Url (..),
    eventId,
    parseRunId,
    runIdText,
 )
import State.Run.Id (eventIdText, parseEventId)
import State.Step.Artifact (areaText, branchText, decodeBreakdown, judgementText, named, shaText, taskIdText, topicText, urlText)
import State.Step.Catalog (outcomeData, outcomeDecoders, outcomeEvent)
import System.FilePath ((</>))

-- | The log's file in a run's notes dir.
logName :: FilePath
logName = "events.jsonl"

logOf :: FilePath -> FilePath
logOf notes = notes </> logName

-- | The log version this kernel writes and reads.
version :: Int
version = 3

-- | Why a line was not read.
data LineError
    = -- | Another log version: 1 and 2 are the Python @state@'s.
      Unsupported Int
    | Malformed Text
    deriving stock (Eq, Show)

-- | The first line not read, counted from 1.
data LogError = LogError {line :: Int, why :: LineError}
    deriving stock (Eq, Show)

-- | Every line, or the first that is not read.
decodeLog :: Text -> Either LogError [Envelope]
decodeLog = traverse numbered . zip [1 ..] . Text.lines
  where
    numbered (n, raw) = first (LogError n) (decodeLine raw)

-- | A log file's bytes; bytes that are not UTF-8 are line 0's error.
decodeLogBytes :: ByteString -> Either LogError [Envelope]
decodeLogBytes = either (const (Left (LogError 0 (Malformed "the log is not UTF-8")))) decodeLog . decodeUtf8'

-- | The bytes that append these lines to a log, each ending in a newline.
encodeLines :: [Envelope] -> ByteString
encodeLines = encodeUtf8 . foldMap ((<> "\n") . encodeLine)

-- | How much of a log 'firstLineOf' reads, so a huge log is not read whole.
firstLineBytes :: Int
firstLineBytes = 65536

-- | A log's first line, read leniently from its first 'firstLineBytes' bytes.
firstLineOf :: ByteString -> Text
firstLineOf = Text.takeWhile (/= '\n') . decodeUtf8Lenient . BS.take firstLineBytes

decodeLine :: Text -> Either LineError Envelope
decodeLine raw = do
    obj <- malformed (eitherDecodeStrictText raw)
    v <- malformed (parseEither lineVersion obj)
    if v == version
        then malformed (parseEither envelope obj)
        else Left (Unsupported v)
  where
    malformed = first (Malformed . Text.pack)

{- | Version 3 names it on every line. A Python log names none, but its
@started@ event carries @version@ from version 2 on.
-}
lineVersion :: Object -> Parser Int
lineVersion obj =
    obj .:? "v" >>= \case
        Just v -> pure v
        Nothing -> do
            event <- obj .:? "event"
            legacy <- maybe (pure Nothing) (.:? "version") event
            pure (fromMaybe 1 legacy)

-- | One line, without its newline, its keys in the order above.
encodeLine :: Envelope -> Text
encodeLine e =
    Lazy.toStrict . Lazy.decodeUtf8 . encodingToLazyByteString . pairs $
        "v" .= version
            <> "id" .= eventIdText (eventId e)
            <> "seq" .= e.seq
            <> "ts" .= e.ts
            <> "run" .= runIdText e.run
            <> "head" .= fmap shaText e.head
            <> "session" .= fmap (\(SessionId session) -> session) e.session
            <> "type" .= eventType e.event
            <> pair "data" (pairs (eventData e.event))

envelope :: Object -> Parser Envelope
envelope obj = do
    n <- obj .: "seq"
    run <- obj .: "run" >>= runIdOf
    source <- obj .: "id" >>= sourceOf run n
    ts <- obj .: "ts"
    sha <- fmap Sha <$> obj .: "head"
    session <- fmap SessionId <$> obj .: "session"
    kind <- obj .: "type"
    event <- obj .: "data" >>= withObject "data" (eventOf kind)
    pure Envelope {source, seq = n, ts, run, head = sha, session, event}

-- | The line's own run and seq are the truth, so a CLI id naming others is refused.
sourceOf :: RunId -> Natural -> Text -> Parser Source
sourceOf run n raw
    | raw == eventIdText (Numbered run n) = pure Cli
    | Just (Hashed digest) <- parseEventId raw = pure (Hook digest)
    | otherwise = fail ("id " <> show raw <> " is neither " <> show (eventIdText (Numbered run n)) <> " nor h:<hash>")

eventType :: Event -> Text
eventType = \case
    Started _ -> "started"
    QualitySet _ -> "quality"
    SizeSet _ -> "size"
    Grew _ -> "grew"
    Took outcome -> eventText (outcomeEvent outcome)
    Stopped _ -> "stop"
    Overridden _ _ -> "overridden"
    Refused _ -> "refused"
    Asked _ -> "asked"
    RetaggedSecurity _ -> "retagged"
    RuledOn _ _ -> "ruled"
    Forwarded _ _ -> "forwarded"
    Answered {} -> "answered"
    Spawning _ -> "spawning"
    Spawned _ -> "spawned"
    Resumed _ -> "resumed"
    HandedBack _ _ -> "handed_back"
    TaskMoved _ _ -> "task"
    Held _ _ -> "held"
    ActedOn _ _ -> "acted"
    WorkerHandedBack _ _ -> "worker_handed_back"

eventData :: Event -> Series
eventData = \case
    Started start ->
        "flow" .= flowText start.flow
            <> "notes" .= start.notes
            <> pair "principal" (principalEncoding start.principal)
            <> "interface" .= map opText (Set.toList start.interface)
    QualitySet quality -> "mode" .= qualityName quality
    SizeSet size -> "size" .= sizeName size
    Grew why -> "why" .= why
    Took outcome -> outcomeData outcome
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
    Answered qid answer by -> qidData qid <> "answer" .= answer <> pair "by" (aboveEncoding by)
    Spawned child ->
        "child" .= runIdText child.run
            <> "task" .= taskIdText child.task
            <> "log" .= child.log
            <> "worktree" .= child.worktree
    Spawning task -> "task" .= taskIdText task
    Resumed child -> "child" .= runIdText child
    HandedBack child said -> "child" .= runIdText child <> saidData said
    TaskMoved task moved -> "task" .= taskIdText task <> taskStateData moved
    Held task url -> "task" .= taskIdText task <> "url" .= urlText url
    ActedOn task url -> "task" .= taskIdText task <> "url" .= urlText url
    WorkerHandedBack (AgentRole role) line -> "role" .= role <> "line" .= oneLineText line
  where
    qidData qid = "qid" .= qidText qid

eventOf :: Text -> Object -> Parser Event
eventOf kind obj = case kind of
    "started" -> Started <$> startOf obj
    "quality" -> QualitySet <$> (obj .: "mode" >>= named "quality" parseQuality)
    "size" -> SizeSet <$> (obj .: "size" >>= named "size" (parseByName sizeName))
    "grew" -> Grew <$> obj .: "why"
    "stop" -> Stopped <$> (Stop <$> (obj .: "reason" >>= named "stop reason" (parseByName reasonText)) <*> obj .: "why")
    "overridden" -> Overridden . StateName <$> obj .: "to" <*> obj .: "why"
    "refused" -> Refused <$> (Note <$> obj .: "message" <*> obj .: "fix")
    "asked" -> Asked <$> askingOf obj
    "retagged" -> RetaggedSecurity <$> qidOf obj <* (obj .: "kind" >>= security)
    "ruled" -> RuledOn <$> qidOf obj <*> (Proposal <$> oneLineAt "answer" obj <*> oneLineAt "why" obj <*> oneLineAt "cost" obj <*> (obj .: "basis" >>= traverse basisOf))
    "forwarded" -> Forwarded <$> qidOf obj <*> (obj .: "to" >>= aboveOf)
    "answered" -> Answered <$> qidOf obj <*> obj .: "answer" <*> (obj .: "by" >>= aboveOf)
    "spawned" -> Spawned <$> (Child <$> childOf obj <*> taskOf obj <*> obj .: "log" <*> obj .: "worktree")
    "spawning" -> Spawning <$> taskOf obj
    "resumed" -> Resumed <$> childOf obj
    "handed_back" -> HandedBack <$> childOf obj <*> saidOf obj
    "task" -> TaskMoved <$> taskOf obj <*> taskStateOf obj
    "held" -> Held <$> taskOf obj <*> (Url <$> obj .: "url")
    "acted" -> ActedOn <$> taskOf obj <*> (Url <$> obj .: "url")
    "worker_handed_back" -> WorkerHandedBack . AgentRole <$> obj .: "role" <*> oneLineAt "line" obj
    _ -> case Map.lookup kind outcomeParsers of
        Just parser -> Took <$> parser obj
        Nothing -> fail ("unknown event type " <> show kind)

-- | Keyed by the event names the layers give each outcome, so a renamed outcome changes the wire with it.
outcomeParsers :: Map Text (Object -> Parser AnyOutcome)
outcomeParsers = Map.fromList (map (first eventText) outcomeDecoders)

childOf :: Object -> Parser RunId
childOf obj = obj .: "child" >>= runIdOf

taskOf :: Object -> Parser TaskId
taskOf obj = TaskId <$> obj .: "task"

{- | #360's @token@, @ref@ and @qid@: the hand-back's line 1 as the child
sent it, a stop's as 'stopWire' spells it.
-}
saidData :: Said -> Series
saidData said = "token" .= token <> "ref" .= ref <> "qid" .= fmap qidText qid
  where
    (token, ref, qid) = case said of
        Finished summary -> ("READY", Just (oneLineText summary), Nothing)
        AsksUp asked -> ("NEEDS_DECISION", Nothing, Just asked)
        AwaitsCi on -> ("AWAIT", Just (oneLineText on), Nothing)
        Ended stop -> let (word, payload) = stopWire stop in (word, Just payload, Nothing)

saidOf :: Object -> Parser Said
saidOf obj =
    obj .: "token" >>= \case
        "READY" -> Finished <$> oneLineAt "ref" obj
        "AWAIT" -> AwaitsCi <$> oneLineAt "ref" obj
        token ->
            obj .:? "ref" >>= \case
                Nothing | token == "NEEDS_DECISION" -> AsksUp <$> qidOf obj
                ref -> maybe (fail ("no hand-back token: " <> show token)) (pure . Ended) (parseStop token (fromMaybe "" ref))

{- | A stop on the wire (#360): its hand-back token, and the prefix its why
takes there. The one spelling of a stop, read by the log and the hand-back.
-}
stopToken :: StopReason -> (Text, Text)
stopToken = \case
    Blocked -> ("BLOCKED", "")
    Failed -> ("FAILED", "")
    Replan -> ("NEEDS_DECISION", "plan wrong: ")
    Fuel -> ("BLOCKED", "out of fuel: ")
    Outgrown -> ("GREW", "")

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

{- | The prefixed reasons are tried first, so @BLOCKED out of fuel: x@ reads as
'Fuel', as the wire cannot tell it from a 'Blocked' whose why says so.
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
        Parked reason parkedPr -> (Just reason, parkedPr)

taskStateOf :: Object -> Parser TaskState
taskStateOf obj = do
    pr <- fmap Url <$> obj .: "pr"
    name <- obj .: "state"
    case (lookup name prStates, name) of
        (Just state, _) -> maybe (fail ("a task in " <> Text.unpack name <> " names its pr")) (pure . state) pr
        (Nothing, "parked") -> Parked <$> obj .: "why" <*> pure pr
        (Nothing, other) -> fail ("unknown task state " <> show other)

-- | The states that name their PR, by the name 'taskStateName' gives each: @state record task@'s and the log's.
prStates :: [(Text, Url -> TaskState)]
prStates = [("ci", InCi), ("review", InReview), ("merged", Merged)]

-- | As @state record task@ names it.
taskStateName :: TaskState -> Text
taskStateName = \case
    InCi _ -> "ci"
    InReview _ -> "review"
    Merged _ -> "merged"
    Parked _ _ -> "parked"

-- | The arguments @state record task@ takes after the task's id for this state.
taskStateArgs :: TaskState -> Text
taskStateArgs moved =
    Text.unwords $
        taskStateName moved : case moved of
            InCi pr -> [urlText pr]
            InReview pr -> [urlText pr]
            Merged pr -> [urlText pr]
            Parked why pr -> why : maybe [] (\url -> ["--pr", urlText url]) pr

startOf :: Object -> Parser Start
startOf obj =
    Start
        <$> (obj .: "flow" >>= named "flow" (parseByName flowText))
        <*> obj .: "notes"
        <*> (obj .: "principal" >>= principalOf)
        <*> (Set.fromList <$> (obj .: "interface" >>= traverse (named "operation" (parseByName opText))))

-- | The user is a bare word; a parent run is its id, its log and the task it gave.
principalEncoding :: Principal -> Encoding
principalEncoding = \case
    ByUser -> text "user"
    ByRole parent -> pairs ("run" .= runIdText parent.run <> "log" .= parent.log <> "task" .= taskIdText parent.task)

principalOf :: Value -> Parser Principal
principalOf = \case
    String "user" -> pure ByUser
    Object obj -> fmap ByRole $ Parent <$> (obj .: "run" >>= runIdOf) <*> obj .: "log" <*> taskOf obj
    other -> fail ("a principal is \"user\" or {run, log}, not " <> show other)

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
    | otherwise = fail ("a question is only ever re-tagged as Security, not " <> show raw)

-- | The run itself is a bare word; a subagent is its role, a child run its id.
askerEncoding :: Asker -> Encoding
askerEncoding = \case
    Itself -> text "self"
    Subagent (AgentRole role) -> pairs ("role" .= role)
    ChildRun run -> pairs ("run" .= runIdText run)

askerOf :: Value -> Parser Asker
askerOf = \case
    String "self" -> pure Itself
    Object obj -> obj .:? "role" >>= maybe (ChildRun <$> (obj .: "run" >>= runIdOf)) (pure . Subagent . AgentRole)
    other -> fail ("a question is from \"self\", {role} or {run}, not " <> show other)

-- | As a principal: the user is a bare word, a parent run is its id.
aboveEncoding :: Above -> Encoding
aboveEncoding = \case
    TheUser -> text "user"
    ParentRun run -> pairs ("run" .= runIdText run)

aboveOf :: Value -> Parser Above
aboveOf = \case
    String "user" -> pure TheUser
    Object obj -> ParentRun <$> (obj .: "run" >>= runIdOf)
    other -> fail ("\"user\" or {run}, not " <> show other)

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
runIdOf raw = maybe (fail ("run id " <> show raw <> " is empty, h, or holds a colon or a line break")) pure (parseRunId raw)

flowText :: FlowName -> Text
flowText = roleText . (.name) . Role.role

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
    Fuel -> "fuel"
    Outgrown -> "grew"
