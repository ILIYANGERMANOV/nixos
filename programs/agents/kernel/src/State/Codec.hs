{- | The log on the wire: one JSON object per line, version 3.

> {"v":3,"id":"r7f2:12","seq":12,"ts":"...","run":"r7f2","head":"abc123",
>  "session":null,"type":"review.rows","data":{"head":"abc123"}}

A step event's @type@ is its edge's name in the flow's graph. A log the
Python @state@ wrote (versions 1 and 2, no @v@ on the line) is refused, not
read: the rewrite breaks it on purpose.
-}
module State.Codec (
    version,
    encodeLine,
    decodeLine,
    decodeLog,
    LineError (..),
    LogError (..),
    eventType,
    areaText,
    reasonText,
    judgementText,
    flowText,
    opText,
    shaText,
    urlText,
) where

import Data.Aeson (Key, Object, Value (..), eitherDecodeStrictText, withObject, (.:), (.:?), (.=))
import Data.Aeson.Encoding (Encoding, encodingToLazyByteString, list, null_, pair, pairs, text)
import Data.Aeson.Types (Parser, Series, parseEither)
import Data.Bifunctor (first)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Lazy qualified as Lazy
import Data.Text.Lazy.Encoding qualified as Lazy
import Numeric.Natural (Natural)
import State.Ask (Above (..), Basis (..), Kind (Security), OneLine, Proposal (..), QId, Question (..), kindName, oneLineText, parseKind, parseOneLine, parseQId, qidText)
import State.Cap (EventName, Step (..), continueEvent, eventText, exitEvent, skipEvent)
import State.Event (
    AgentRole (..),
    Asker (..),
    Asking (..),
    Branch (..),
    Check (..),
    Commit (..),
    DraftPr (..),
    Envelope (..),
    Event (..),
    EventId (..),
    FlowName (..),
    Judgement (..),
    Label (..),
    Note (..),
    Op (..),
    Outcome (..),
    Picks (..),
    Principal (..),
    Requirement (..),
    RunId,
    SessionId (..),
    Sha (..),
    Source (..),
    Start (..),
    StateName (..),
    Stop (..),
    StopReason (..),
    Url (..),
    eventId,
    outcomeEvent,
    parseRunId,
    runIdText,
 )
import State.Id (eventIdText, parseEventId)
import State.Mode (Area (..), parseByName, parseQuality, qualityName, sizeName)

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

eventData :: Event -> Series
eventData = \case
    Started start ->
        "flow" .= flowText start.flow
            <> "notes" .= start.notes
            <> pair "principal" (principalEncoding start.principal)
            <> "interface" .= map opText (Set.toList start.interface)
            <> "task" .= start.task
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
    _ -> case Map.lookup kind outcomeParsers of
        Just parser -> Took <$> parser obj
        Nothing -> fail ("unknown event type " <> show kind)

startOf :: Object -> Parser Start
startOf obj =
    Start
        <$> (obj .: "flow" >>= named "flow" (parseByName flowText))
        <*> obj .: "notes"
        <*> (obj .: "principal" >>= principalOf)
        <*> (Set.fromList <$> (obj .: "interface" >>= traverse (named "operation" (parseByName opText))))
        <*> obj .: "task"

-- | The user is a bare word; a parent run is its id and its log.
principalEncoding :: Principal -> Encoding
principalEncoding = \case
    ByUser -> text "user"
    ByRole run logPath -> pairs ("run" .= runIdText run <> "log" .= logPath)

principalOf :: Value -> Parser Principal
principalOf = \case
    String "user" -> pure ByUser
    Object obj -> ByRole <$> (obj .: "run" >>= runIdOf) <*> obj .: "log"
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

outcomeData :: Outcome -> Series
outcomeData = \case
    ResearchDone n -> "n" .= n
    ResearchSkipped -> mempty
    InterviewEnough -> mempty
    InterviewMore -> mempty
    PlanDone path -> "path" .= path
    SimplifyPlanDone -> mempty
    SimplifyPlanSkipped -> mempty
    AlternativeDone -> mempty
    AlternativeSkipped -> mempty
    ConfirmConfirmed -> mempty
    ConfirmAdjusted -> mempty
    DraftDone draft -> "url" .= urlText draft.url <> "base" .= branchText draft.base <> "branch" .= branchText draft.branch
    ImplementDone commit -> commitData commit
    RefactorDone sha -> headData sha
    RefactorSkipped why -> "why" .= why
    ReviewClean sha -> headData sha
    ReviewRows sha -> headData sha
    PickFinal picks -> picksData picks
    PickLoop picks -> picksData picks
    FixDone commit -> commitData commit
    DescribeDone sha -> headData sha
    SimplifyPrDone sha -> headData sha
    SimplifyPrSkipped sha -> headData sha
    AwaitCiGreen sha -> headData sha
    AwaitCiRed sha failing -> headData sha <> "failing" .= map (\(Check check) -> check) (NonEmpty.toList failing)
    FixPrDone sha -> headData sha
    ReadyDone url -> "url" .= urlText url
    ReadySkipped url -> "url" .= urlText url
  where
    headData sha = "head" .= shaText sha
    commitData commit = headData commit.head <> "touches" .= map areaText (Set.toList commit.touches)
    picksData picks =
        "rows" .= map (\(Label label) -> label) (Set.toList picks.rows)
            <> pair "verdicts" (list verdictEncoding (Map.toList picks.verdicts))
    verdictEncoding (Requirement requirement, judgement) =
        pairs ("requirement" .= requirement <> "outcome" .= judgementText judgement)

{- | Keyed by the event names "State.Cap" gives each outcome, so a renamed
outcome changes the wire with it.
-}
outcomeParsers :: Map Text (Object -> Parser Outcome)
outcomeParsers =
    Map.fromList . map (first eventText) $
        [ continueEvent Research ~> \obj -> ResearchDone <$> obj .: "n"
        , skipEvent Research ~> none ResearchSkipped
        , exitEvent Interview ~> none InterviewEnough
        , continueEvent Interview ~> none InterviewMore
        , continueEvent PlanS ~> \obj -> PlanDone <$> obj .: "path"
        , continueEvent SimplifyP ~> none SimplifyPlanDone
        , skipEvent SimplifyP ~> none SimplifyPlanSkipped
        , continueEvent Alternative ~> none AlternativeDone
        , skipEvent Alternative ~> none AlternativeSkipped
        , exitEvent Confirm ~> none ConfirmConfirmed
        , continueEvent Confirm ~> none ConfirmAdjusted
        , continueEvent Draft ~> fmap DraftDone . draftOf
        , continueEvent Implement ~> fmap ImplementDone . commitOf
        , continueEvent Refactor ~> fmap RefactorDone . headOf
        , skipEvent Refactor ~> \obj -> RefactorSkipped <$> obj .: "why"
        , exitEvent Review ~> fmap ReviewClean . headOf
        , continueEvent Review ~> fmap ReviewRows . headOf
        , exitEvent Pick ~> fmap PickFinal . picksOf
        , continueEvent Pick ~> fmap PickLoop . picksOf
        , continueEvent Fix ~> fmap FixDone . commitOf
        , continueEvent Describe ~> fmap DescribeDone . headOf
        , continueEvent SimplifyPR ~> fmap SimplifyPrDone . headOf
        , skipEvent SimplifyPR ~> fmap SimplifyPrSkipped . headOf
        , exitEvent AwaitCi ~> fmap AwaitCiGreen . headOf
        , continueEvent AwaitCi ~> \obj -> AwaitCiRed <$> headOf obj <*> (fmap Check <$> obj .: "failing")
        , continueEvent FixPR ~> fmap FixPrDone . headOf
        , continueEvent Ready ~> fmap ReadyDone . urlOf
        , skipEvent Ready ~> fmap ReadySkipped . urlOf
        ]
  where
    none outcome _ = pure outcome
    headOf obj = Sha <$> obj .: "head"
    urlOf obj = Url <$> obj .: "url"
    draftOf obj = DraftPr <$> urlOf obj <*> (Branch <$> obj .: "base") <*> (Branch <$> obj .: "branch")
    commitOf obj = Commit <$> headOf obj <*> (Set.fromList <$> (obj .: "touches" >>= traverse (named "area" (parseByName areaText))))
    picksOf obj =
        Picks
            <$> (obj .: "rows" >>= distinct "row" . map Label)
            <*> (obj .: "verdicts" >>= traverse (withObject "verdict" verdictOf) >>= keyed "requirement")
    verdictOf obj = (,) . Requirement <$> obj .: "requirement" <*> (obj .: "outcome" >>= named "outcome" (parseByName judgementText))

{- | A list read as a set, refusing a repeat: a set would keep one copy
silently, and a log naming one twice is a bug in its writer.
-}
distinct :: (Ord a) => String -> [a] -> Parser (Set a)
distinct what = fmap Map.keysSet . keyed what . map (,())

-- | Pairs read as a map, refusing a repeated key, where a map would keep the last.
keyed :: (Ord k) => String -> [(k, v)] -> Parser (Map k v)
keyed what entries
    | Map.size byKey == length entries = pure byKey
    | otherwise = fail ("repeated " <> what)
  where
    byKey = Map.fromList entries

(~>) :: EventName -> (Object -> Parser Outcome) -> (EventName, Object -> Parser Outcome)
(~>) = (,)

infixr 0 ~>

named :: String -> (Text -> Maybe a) -> Text -> Parser a
named what parse raw = maybe (fail ("unknown " <> what <> " " <> show raw)) pure (parse raw)

oneLineAt :: Key -> Object -> Parser OneLine
oneLineAt key obj = obj .: key >>= oneLineOf

oneLineOf :: Text -> Parser OneLine
oneLineOf raw = maybe (fail (show raw <> " holds a line break")) pure (parseOneLine raw)

runIdOf :: Text -> Parser RunId
runIdOf raw = maybe (fail ("run id " <> show raw <> " is empty, h, or holds a colon or a line break")) pure (parseRunId raw)

shaText :: Sha -> Text
shaText (Sha sha) = sha

urlText :: Url -> Text
urlText (Url url) = url

branchText :: Branch -> Text
branchText (Branch branch) = branch

flowText :: FlowName -> Text
flowText = \case
    EngineerFlow -> "engineer"
    TenXFlow -> "10x"

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

-- | As a review's verdict table spells them.
judgementText :: Judgement -> Text
judgementText = \case
    Met -> "met"
    NotMet -> "not-met"
    Unverified -> "unverified"

areaText :: Area -> Text
areaText = \case
    Interface -> "interface"
    DataModel -> "data-model"
    Auth -> "auth"
