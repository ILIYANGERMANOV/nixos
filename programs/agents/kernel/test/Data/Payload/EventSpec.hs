{- | An envelope as an @events@ row and back, the @runs@ row of a run's
first event, and the payload's JSON: its bytes, its laws and its spellings.
-}
module Data.Payload.EventSpec (spec) where

import Data.Aeson (Object, Value (..), encode, toJSON, withObject, (.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Decoding.Text (textToTokens)
import Data.Aeson.Decoding.Tokens (TkArray (..), TkRecord (..), Tokens (..))
import Data.Aeson.Key (Key)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.Char (isAsciiLower, isDigit)
import Data.Entity.Event (EventRow (..))
import Data.Entity.Event qualified as Row
import Data.Entity.Run (RunRow (..))
import Data.Foldable (for_, toList)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Payload.Event (
    Decoded (..),
    RetiredEvent (..),
    UnknownEvent (..),
    decodeRow,
    dumpLine,
    eventRow,
    questionKindName,
    runRow,
    taskStateKind,
 )
import Data.Payload.Fixtures (retiring)
import Data.Payload.Upcast (shipped)
import Data.Set qualified as Set
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Lazy qualified as Lazy
import Data.Text.Lazy.Encoding qualified as Lazy
import Data.Time (UTCTime (..), fromGregorian)
import Hedgehog (
    Gen,
    LabelName,
    annotate,
    assert,
    cover,
    failure,
    forAll,
    label,
    tripping,
    (===),
 )
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import State.Artifact (
    Artifact (File),
    FileArtifact (..),
    FileKind (Plan),
    FileRef (..),
    Size (..),
    UrlKind (Pr),
    fileKindText,
    sha256Of,
    urlKindText,
 )
import State.Artifact qualified as Registry (Artifact (Url))
import State.Category.Flow (scopePath, unqualify)
import State.Category.Fuel (Fuel (..), fuelName)
import State.Golden (golden)
import State.Run.Ask (
    Above (..),
    Basis (..),
    ChildTask (..),
    Kind (..),
    Link (..),
    Parent (..),
    Principal (..),
    Proposal (..),
    QId (..),
    Question (..),
 )
import State.Run.Codec (
    eventType,
    flowText,
    handoverReasonText,
    reasonText,
    topicText,
    waitingText,
 )
import State.Run.Event (
    AgentId (..),
    AgentRole (..),
    AnyOutcome,
    Asker (..),
    Asking (..),
    Branch (..),
    Check (..),
    Child (..),
    Commit (..),
    Digest (..),
    DraftPr (..),
    Envelope (..),
    Event (..),
    EventId (..),
    FlowName (..),
    Handover (..),
    HandoverReason (..),
    Harness (..),
    Judgement (..),
    Label (..),
    Note (..),
    Op (..),
    Picks (..),
    PlanCall (..),
    Reply (..),
    Repo (..),
    Requirement (..),
    Said (..),
    Session (..),
    Sha (..),
    Shape (..),
    Source (..),
    Start (..),
    StateName (..),
    Stop (..),
    StopReason (..),
    Target (..),
    Task (..),
    TaskId (..),
    TaskNo (..),
    TaskState (..),
    Url (..),
    Waiting (..),
    stepTook,
    tookIn,
 )
import State.Run.EventGen (
    absolutePath,
    genEnvelope,
    genTaskState,
    genText,
    line,
    oneLine,
    replacing,
    runId,
    tasksOf,
    uri,
 )
import State.Run.RunGen (pickOf, plainTask, securityScope)
import State.Step.Artifact (areaName, judgementName, planName, shellPath)
import State.Step.Artifact qualified as Artifact (Task (..))
import State.Step.Build (Outcome (..))
import State.Step.Catalog (outcome)
import State.Step.Fan (Outcome (..), engineers)
import State.Step.Fuel (Outcome (..))
import State.Step.Gather (Outcome (..))
import State.Step.Plan (Outcome (..))
import State.Step.Request (Outcome (..))
import State.Step.Review (Outcome (..))
import State.Step.Ship (Outcome (..))
import State.Step.Ticket (Outcome (..))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.Hspec.Hedgehog (hedgehog, modifyMaxSuccess)

spec :: Spec
spec = describe "Data.Payload.Event" $ do
    -- Enough cases that every event type, about 30, is drawn some 30 times.
    modifyMaxSuccess (const 1000) $ do
        it "envelope_row_round_trips: every event type's row decodes to it" . hedgehog $ do
            e <- forAll genEnvelope
            label (typeOf e)
            tripping e eventRow (known . decodeRow shipped)

        it
            "dump_line_round_trips: state dump's line of a row reads back as its envelope"
            . hedgehog
            $ do
                e <- forAll genEnvelope
                label (typeOf e)
                tripping e encodeLine decodeLine

        it "writes_no_duplicate_key: no object of a payload repeats a key, at any depth"
            . hedgehog
            $ do
                e <- forAll genEnvelope
                label (typeOf e)
                repeatedKeys (eventRow e).payload === Right []

        it "decodes_any_object_under_its_type: as an event of that type, or as unknown"
            . hedgehog
            $ do
                e <- forAll genEnvelope
                label (typeOf e)
                payload <-
                    forAll $
                        Gen.choice
                            [ atSomeObject nearby (payloadValue (eventRow e).payload)
                            , Object <$> genObject
                            ]
                let row = (eventRow e) {Row.payload = jsonText payload}
                case decodeRow shipped row of
                    Known decoded -> do
                        cover 10 "known" True
                        decodeRow shipped (eventRow decoded) === Known decoded
                    Retired _ -> do
                        annotate "a kernel that retires no type read a row as retired"
                        failure
                    Unknown u -> do
                        cover 10 "unknown" True
                        u === unknownOf row

        it
            "ignores_an_extra_key: an event's payload with a key more, at any depth, reads as the event"
            . hedgehog
            $ do
                e <- forAll genEnvelope
                label (typeOf e)
                -- No key the codec reads starts with x_.
                key <- forAll (Key.fromText . ("x_" <>) <$> genText)
                extra <- forAll genJson
                payload <-
                    forAll
                        ( atSomeObject
                            (pure . KeyMap.insert key extra)
                            (payloadValue (eventRow e).payload)
                        )
                decodeRow shipped (eventRow e) {Row.payload = jsonText payload} === Known e

    it "decode_is_total: any row decodes, its type and data kept when not known"
        . hedgehog
        $ do
            row <- forAll genAnyRow
            -- A known row is rare here: the round trip above covers it.
            case decodeRow retiring row of
                Known e -> e.seq === fromIntegral row.seq
                Retired r -> do
                    cover 5 "retired" True
                    (r.eventType, r.payload) === (row.eventType, row.payload)
                Unknown u -> do
                    cover 50 "unknown" True
                    (u.eventType, u.schemaVersion, u.payload)
                        === (row.eventType, row.schemaVersion, row.payload)

    describe
        "writes each event type's payload as its golden pins, one per case of its unions"
        $ for_ eventGoldens
        $ \events ->
            let name = Text.unpack (eventType (NonEmpty.head events))
             in it name $ golden ("payload/" <> name <> ".json") (payloads events)

    describe "writes each step outcome's payload shape as its golden pins" $
        for_ outcomeGoldens $ \(shape, outcomes) ->
            it shape $
                golden
                    ("payload/outcome-" <> shape <> ".json")
                    (payloads (Took mempty <$> outcomes))

    it "spells every case of each enum the log writes in lowercase snake_case" $
        filter (not . snakeCase) enumSpellings
            `shouldBe` []

    it "spells every task state's kind in lowercase snake_case" . hedgehog $ do
        state <- forAll genTaskState
        label (fromString (Text.unpack (taskStateKind state)))
        assert (snakeCase (taskStateKind state))

    it "writes an envelope's columns, payload version 1" $
        eventRow refused
            `shouldBe` EventRow
                { runId = "00010203"
                , seq = 2
                , schemaVersion = 1
                , eventType = "refused"
                , time = "2026-11-13T00:00:00.000Z"
                , sessionId = Nothing
                , headSha = Nothing
                , hookDigest = Nothing
                , payload = "{\"message\":\"n\",\"fix\":\"f\"}"
                }

    it "makes a child's runs row from its first event alone" $
        runRow begun
            `shouldBe` Just
                RunRow
                    { id = "0a0b0c0d"
                    , parentRunId = Just "00010203"
                    , flow = "engineer"
                    , notesDir = "/child"
                    , createdAt = "2026-11-13T00:00:00.000Z"
                    }

    it "makes no runs row of an event past the first" $
        runRow refused `shouldBe` Nothing

    it "reads a row of a newer payload version as unknown" $
        decodeRow shipped (eventRow refused) {Row.schemaVersion = 2}
            `shouldBe` Unknown (unknownOf (eventRow refused) {Row.schemaVersion = 2})

    it "reads a row whose type it does not know as unknown" $
        decodeRow shipped (eventRow refused) {Row.eventType = "no_such_event"}
            `shouldBe` Unknown (unknownOf (eventRow refused) {Row.eventType = "no_such_event"})

    it "reads a row whose payload does not fit its type as unknown" $
        decodeRow shipped (eventRow refused) {Row.payload = "{}"}
            `shouldBe` Unknown (unknownOf (eventRow refused) {Row.payload = "{}"})

    it
        "reads an artifact whose kind fits not its location, or a relative path, as unknown"
        $ let row payload = (eventRow refused) {Row.eventType = "artifact", Row.payload = payload}
              file kind path =
                "{\"artifact_kind\":\""
                    <> kind
                    <> "\",\"location\":{\"kind\":\"file\",\"path\":\""
                    <> path
                    <> "\",\"sha256\":\""
                    <> Text.replicate 64 "a"
                    <> "\",\"size_bytes\":1}}"
              url kind =
                "{\"artifact_kind\":\""
                    <> kind
                    <> "\",\"location\":{\"kind\":\"url\",\"url\":\"https://x.org\"}}"
              misfits = [file "pr" "/a", url "plan", file "plan" "a/b"]
           in map (decodeRow shipped . row) misfits
                `shouldBe` map (Unknown . unknownOf . row) misfits

    it "reads an aliased type as the type it names" $
        decodeRow retiring (eventRow refused) {Row.eventType = "refusal"}
            `shouldBe` Known refused

    it "reads a row of a retired type as retired, its hook digest kept" $
        decodeRow
            retiring
            (eventRow refused)
                { Row.eventType = "legacy.note"
                , Row.payload = "{\"old\":1}"
                , Row.hookDigest = Just "0123456789abcdef"
                }
            `shouldBe` Retired
                RetiredEvent
                    { eventType = "legacy.note"
                    , payload = "{\"old\":1}"
                    , digest = Just (Digest "0123456789abcdef")
                    }

    it "reads a retired type as unknown to a kernel that never retired it" $
        decodeRow shipped (eventRow refused) {Row.eventType = "legacy.note"}
            `shouldBe` Unknown (unknownOf (eventRow refused) {Row.eventType = "legacy.note"})

    it "dumps a row as one JSON object, null for NULL, data verbatim" $
        dumpLine (eventRow refused) {Row.payload = "{\"b\":1,\"a\":2,\"a\":3}"}
            `shouldBe` "{\"run_id\":\"00010203\",\"seq\":2,\"schema_version\":1,\"type\":\"refused\",\"time\":\"2026-11-13T00:00:00.000Z\",\"session_id\":null,\"head_sha\":null,\"hook_digest\":null,\"data\":{\"b\":1,\"a\":2,\"a\":3}}"

    it "dumps the row #360 documents, its columns in the table's order" $
        encodeLine reviewRows
            `shouldBe` "{\"run_id\":\"r7f2\",\"seq\":12,\"schema_version\":1,\"type\":\"review.rows\",\"time\":\"2026-11-12T10:00:00.000Z\",\"session_id\":null,\"head_sha\":\"0123456789abcdef0123456789abcdef01234567\",\"hook_digest\":null,\"data\":{\"head_sha\":\"abc123\"}}"

    it "reads a row of run h, whose CLI ids read as hook ids, as unknown" $
        decodeLine
            (encodeLine reviewRows `replacing` ("\"run_id\":\"r7f2\"", "\"run_id\":\"h\""))
            `shouldSatisfy` malformed

    it "refuses a parent run h" $
        decodeLine
            ( encodeLine parentRun
                `replacing` ("\"run\":\"r7f2\",\"link\"", "\"run\":\"h\",\"link\"")
            )
            `shouldSatisfy` malformed

    it "reads a step's outcome inside a scope under its qualified type" $
        decodeLine
            ( encodeLine reviewRows
                `replacing` ("\"type\":\"review.rows\"", "\"type\":\"security/review.rows\"")
            )
            `shouldBe` Right reviewRows {event = tookIn securityScope (ReviewRows (Sha "abc123"))}

    it "reads a choice's enough inside a scope under its qualified type" $
        decodeLine
            ( encodeLine reviewRows {event = Took mempty (pickOf "gather" "enough")}
                `replacing` ("\"type\":\"gather.enough\"", "\"type\":\"x/gather.enough\"")
            )
            `shouldBe` Right reviewRows {event = Took (scopePath "x") (pickOf "gather" "enough")}

    it
        "writes the chief's picks under their route's and branch's names, a block's inside the blocks' route"
        $ map ((.eventType) . eventRow) chiefPicks
            `shouldBe` ["route.engineer", "block.shipping"]

    it "reads the chief's picks back by their route's and branch's names" $
        map (fmap (.event) . decodeLine . encodeLine) chiefPicks
            `shouldBe` map (Right . (.event)) chiefPicks

    it "refuses a run's event inside a scope: only a step's outcome is named so" $
        decodeLine
            ( encodeLine reviewRows {event = Extended "why"}
                `replacing` ("\"type\":\"extend\"", "\"type\":\"security/extend\"")
            )
            `shouldSatisfy` malformed

    it "refuses a red CI result with no failing check" $
        decodeLine
            ( encodeLine reviewRows
                `replacing` ("review.rows", "await_ci.red")
                `replacing` ("{\"head_sha\":\"abc123\"}", "{\"head_sha\":\"abc123\",\"failing\":[]}")
            )
            `shouldSatisfy` malformed

    it "refuses a session start whose harness is empty" $
        decodeLine
            ( encodeLine
                reviewRows
                    { event = SessionStarted (Session (Harness "opencode") Nothing "resume" Nothing)
                    }
                `replacing` ("\"harness\":\"opencode\"", "\"harness\":\"\"")
            )
            `shouldSatisfy` malformed

    it "refuses picks naming a row twice" $
        decodeLine
            (encodeLine picked `replacing` ("\"rows\":[\"A\"]", "\"rows\":[\"A\",\"A\"]"))
            `shouldSatisfy` malformed

    it "refuses picks judging a requirement twice" $
        decodeLine
            ( encodeLine picked
                `replacing` (metR1, metR1 <> ",{\"requirement\":\"R1\",\"outcome\":\"not_met\"}")
            )
            `shouldSatisfy` malformed

    it "reads a voided seq of 2^53 - 1, I-JSON's largest integer" $
        (.event) <$> decodeLine (voidingSeq "9007199254740991")
            `shouldBe` Right (Voided 9007199254740991 "r")

    it "reads a voided seq of 2^53, past I-JSON's integers, as unknown" $
        decodeLine (voidingSeq "9007199254740992") `shouldSatisfy` malformed

    it "refuses a ruling whose answer breaks the line" $
        decodeLine
            ( encodeLine
                reviewRows
                    { event =
                        RuledOn
                            (QId (runId "c1") 3)
                            (Proposal (oneLine "v2") (oneLine "why") (oneLine "cost") Nothing)
                    }
                `replacing` ("\"answer\":\"v2\"", "\"answer\":\"v2\\nREADY\"")
            )
            `shouldSatisfy` malformed

    it "refuses an AWAIT that names nothing it awaits" $
        decodeLine
            ( encodeLine
                reviewRows
                    { event = HandedBack (runId "c1") (Awaits Merge (oneLine "https://pr/1"))
                    }
                `replacing` (",\"on\":\"merge\"", "")
            )
            `shouldSatisfy` malformed

    it "refuses a retag to any kind but security" $
        decodeLine
            ( encodeLine reviewRows {event = RetaggedSecurity (QId (runId "c1") 3)}
                `replacing` ("\"question_kind\":\"security\"", "\"question_kind\":\"design\"")
            )
            `shouldSatisfy` malformed
  where
    refused =
        Envelope
            { source = Cli
            , seq = 2
            , ts = UTCTime (fromGregorian 2026 11 13) 0
            , run = runId "00010203"
            , head = Nothing
            , session = Nothing
            , event = Refused (Note "n" "f")
            }
    begun =
        refused
            { seq = 1
            , run = runId "0a0b0c0d"
            , event =
                Started
                    Start
                        { flow = EngineerFlow
                        , notes = "/child"
                        , principal =
                            ByRole (Parent (runId "00010203") (InFan (Tasked (TaskId "t1")))) OwnPr minBound
                        , interface = Set.empty
                        , goal = Nothing
                        , worktree = absolutePath "/work"
                        , repo = Nothing
                        }
            }

-- | The envelope a row decodes to, or why not.
known :: Decoded -> Either Decoded Envelope
known = \case
    Known e -> Right e
    other -> Left other

-- | The row as unknown to this kernel: its type, version and data as stored.
unknownOf :: EventRow -> UnknownEvent
unknownOf row =
    UnknownEvent
        { eventType = row.eventType
        , schemaVersion = row.schemaVersion
        , payload = row.payload
        }

-- | The event's type, out of any scope: one label per type a property draws.
typeOf :: Envelope -> LabelName
typeOf e = fromString (Text.unpack (snd (unqualify (eventType e.event))))

{- | The keys some object of this JSON text repeats, at any depth, from
aeson's token stream: a decoded 'Value' keeps one of them and hides the rest.
-}
repeatedKeys :: Text -> Either String [Key]
repeatedKeys = fmap fst . value . textToTokens
  where
    value :: Tokens k String -> Either String ([Key], k)
    value = \case
        TkLit _ rest -> Right ([], rest)
        TkText _ rest -> Right ([], rest)
        TkNumber _ rest -> Right ([], rest)
        TkArrayOpen items -> array items
        TkRecordOpen members -> record Set.empty members
        TkErr err -> Left err
    array :: TkArray k String -> Either String ([Key], k)
    array = \case
        TkItem item -> do
            (inItem, items) <- value item
            (inRest, rest) <- array items
            pure (inItem <> inRest, rest)
        TkArrayEnd rest -> Right ([], rest)
        TkArrayErr err -> Left err
    record :: Set.Set Key -> TkRecord k String -> Either String ([Key], k)
    record seen = \case
        TkPair key member -> do
            (inMember, members) <- value member
            (inRest, rest) <- record (Set.insert key seen) members
            pure ([key | Set.member key seen] <> inMember <> inRest, rest)
        TkRecordEnd rest -> Right ([], rest)
        TkRecordErr err -> Left err

-- | The value with one of its objects, at any depth, changed by @change@.
atSomeObject :: (Object -> Gen Object) -> Value -> Gen Value
atSomeObject change = \case
    Object o ->
        Gen.choice $
            (Object <$> change o)
                : [ Object . (\v' -> KeyMap.insert k v' o) <$> atSomeObject change v
                  | (k, v) <- KeyMap.toList o
                  , holdsObject v
                  ]
    Array vs ->
        Gen.choice
            [ (\v' -> toJSON (before <> (v' : after))) <$> atSomeObject change v
            | i <- [0 .. length vs - 1]
            , (before, v : after) <- [splitAt i (toList vs)]
            , holdsObject v
            ]
    other -> pure other
  where
    holdsObject = \case
        Object _ -> True
        Array vs -> any holdsObject vs
        _ -> False

-- | An object one change from this one: a key added, its value replaced, or dropped.
nearby :: Object -> Gen Object
nearby o =
    Gen.choice $
        ( KeyMap.insert
            <$> Gen.choice (keyOf : [Gen.element keys | not (null keys)])
            <*> genJson
            <*> pure o
        )
            : [(`KeyMap.delete` o) <$> Gen.element keys | not (null keys)]
  where
    keys = KeyMap.keys o

-- | Any JSON value, its numbers at the edges of I-JSON's integers.
genJson :: Gen Value
genJson =
    Gen.recursive
        Gen.choice
        [ pure Null
        , Bool <$> Gen.bool
        , Number
            <$> Gen.element [0, -1, 7, 1.5, 9007199254740991, 9007199254740992, 1e300]
        , String <$> genText
        ]
        [toJSON <$> Gen.list (Range.linear 0 3) genJson, Object <$> genObject]

genObject :: Gen Object
genObject = KeyMap.fromList <$> Gen.list (Range.linear 0 3) ((,) <$> keyOf <*> genJson)

keyOf :: Gen Key
keyOf = Key.fromText <$> genText

payloadValue :: Text -> Value
payloadValue raw =
    either
        (error . ("a payload that is no JSON: " <>))
        id
        (Aeson.eitherDecodeStrictText raw)

jsonText :: Value -> Text
jsonText = Lazy.toStrict . Lazy.decodeUtf8 . encode

-- | Every case of each nullary enum a payload holds, as the log spells it.
enumSpellings :: [Text]
enumSpellings =
    concat
        [ map questionKindName [minBound ..]
        , map areaName [minBound ..]
        , map judgementName [minBound ..]
        , map planName [minBound ..]
        , map reasonText [minBound ..]
        , map waitingText [minBound ..]
        , map flowText [minBound ..]
        , map fuelName [minBound ..]
        , map topicText [minBound ..]
        , map fileKindText [minBound ..]
        , map urlKindText [minBound ..]
        , map handoverReasonText [minBound ..]
        ]

-- | Lowercase snake_case: words of @a-z@ and @0-9@, joined by single underscores.
snakeCase :: Text -> Bool
snakeCase =
    all
        ( \word -> not (Text.null word) && Text.all (\c -> isAsciiLower c || isDigit c) word
        )
        . Text.splitOn "_"

-- | These events' payloads as one JSON array, a payload a line, each verbatim.
payloads :: NonEmpty Event -> Text
payloads events =
    "[\n"
        <> Text.intercalate ",\n" [(eventRow (line 1 e)).payload | e <- toList events]
        <> "\n]\n"

{- | An event of each type but a step's outcome, in each case of the unions
it holds: its golden is @payload/<type>.json@.
-}
eventGoldens :: [NonEmpty Event]
eventGoldens =
    [ Started
        ( Start
            EngineerFlow
            "/notes/r7f2"
            (ByUser OwnPr)
            (Set.fromList [minBound ..])
            (Just "ship the context facts")
            (absolutePath "/work/r7f2")
            (Just (Repo "o" "r"))
        )
        :| [ Started
                ( Start
                    ArchitectFlow
                    "/n"
                    (ByCaller (RoundOn pr))
                    Set.empty
                    Nothing
                    (absolutePath "/w")
                    Nothing
                )
           , Started
                ( Start
                    TenXFlow
                    "/n"
                    (ByRole (Parent parent (InFan (Tasked t1))) OwnPr ChildConfirms)
                    (Set.singleton Await)
                    Nothing
                    (absolutePath "/w")
                    Nothing
                )
           , Started
                ( Start
                    EngineerFlow
                    "/n"
                    (ByRole (Parent parent (InFan Untasked)) (RoundOn pr) ParentDecided)
                    Set.empty
                    Nothing
                    (absolutePath "/w")
                    Nothing
                )
           , Started
                ( Start
                    ChiefFlow
                    "/n"
                    (ByRole (Parent parent Direct) OwnPr ChildConfirms)
                    Set.empty
                    Nothing
                    (absolutePath "/w")
                    Nothing
                )
           ]
    , Targeted (OnPr pr)
        :| [Targeted (OnBranch (Branch "feature")), Targeted (OnTicket ticket)]
    , Extended "the plan grew a slice" :| []
    , Gapped "no test drives the CLI's --help" :| []
    , Stopped (Stop Blocked "no access to the repo") :| []
    , Overridden (StateName "review") "the user said so" :| []
    , Refused (Note "no such step" "run state next") :| []
    , Asked
        (Asking (Question qid Design (oneLine "v1 or v2?")) (StateName "plan") Itself)
        :| [ Asked
                ( Asking
                    (Question qid Fact (oneLine "which port?"))
                    (StateName "plan")
                    (Subagent researcher)
                )
           , Asked
                ( Asking
                    (Question qid Stuck (oneLine "what now?"))
                    (StateName "plan")
                    (ChildRun child)
                )
           ]
    , RetaggedSecurity qid :| []
    , ruled Nothing
        :| [ ruled (Just (AnsweredBy (Numbered parent 4)))
           , ruled (Just (AnsweredBy (Hashed (Digest "0123456789abcdef"))))
           , ruled (Just (Obvious (oneLine "the docs say so")))
           ]
    , Forwarded qid TheUser
        :| [Forwarded qid (ParentRun parent), Forwarded qid TheCaller]
    , Answered qid (Chose "v2") TheUser
        :| [ Answered qid (Other "neither") (ParentRun parent)
           , Answered qid (Chose "v1") TheCaller
           ]
    , QuestionParked qid (oneLine "waits on the user") :| []
    , Spawning t1 :| []
    , Spawned (Child child (Tasked t1) "/wt/t1")
        :| [Spawned (Child child Untasked "/wt/c1")]
    , Resumed child :| []
    , HandedBack child (Finished (oneLine "READY https://github.com/o/r/pull/7"))
        :| [ HandedBack child (AsksUp qid)
           , HandedBack child (Awaits Ci (oneLine "https://github.com/o/r/pull/7"))
           , HandedBack child (Awaits Merge (oneLine "https://github.com/o/r/pull/7"))
           , HandedBack child (Ended (Stop OutOfRounds "three rounds, still red"))
           ]
    , TaskMoved t1 (InCi pr)
        :| [ TaskMoved t1 (InReview pr)
           , TaskMoved t1 (Merged pr)
           , TaskMoved t1 (Kept pr)
           , TaskMoved t1 (Round pr)
           , TaskMoved t1 (Parked "waits on a decision" (Just pr))
           , TaskMoved t1 (Parked "waits on a decision" Nothing)
           ]
    , Held t1 pr :| []
    , ActedOn t1 pr :| []
    , TaskAdded everyKey :| [TaskAdded (plainTask "t1" [])]
    , Restarted :| []
    , WorkerHandedBack implementer (oneLine "READY abc123") :| []
    , WorkerSpawned implementer agent :| []
    , WorkerReturned implementer (Just agent) :| [WorkerReturned implementer Nothing]
    , AgentEnded agent :| []
    , Suspended (TaskNo 2) (oneLine "waits on CI") :| []
    , Focused (TaskNo 2) :| []
    , Voided 7 "logged in the wrong run" :| []
    , WorktreeMoved (absolutePath "/work/b") (Just (Repo "o" "r"))
        :| [WorktreeMoved (absolutePath "/work/c") Nothing]
    , ArtifactLogged
        ( File
            ( FileArtifact
                Plan
                (FileRef (absolutePath "/notes/r7f2/plan.md") (sha256Of "abc") (Size 3))
            )
        )
        (Just 4)
        :| [ArtifactLogged (Registry.Url Pr (uri "https://github.com/o/r/pull/7")) Nothing]
    , Noted "decisions" "the cap stays at 1 MiB" :| []
    , HandedOver
        (Handover Context "slice A built" ("build slice B" :| ["open the PR"]))
        :| []
    , SessionStarted
        ( Session
            (Harness "claude-code")
            (Just (absolutePath "/home/u/t.jsonl"))
            "startup"
            (Just "opus")
        )
        :| [SessionStarted (Session (Harness "opencode") Nothing "resume" Nothing)]
    ]
  where
    qid = QId child 3
    parent = runId "r7f2"
    child = runId "c1"
    t1 = TaskId "t1"
    researcher = AgentRole "researcher"
    implementer = AgentRole "implementer"
    agent = AgentId "a1b2"
    ruled =
        RuledOn qid
            . Proposal (oneLine "v2") (oneLine "the docs say so") (oneLine "an hour")

{- | A step outcome of each payload shape, named by the shape: its golden
is @payload/outcome-<shape>.json@. Outcomes of one shape write the same keys.
-}
outcomeGoldens :: [(String, NonEmpty AnyOutcome)]
outcomeGoldens =
    [ ("none", outcome NotesDone :| [])
    , ("level", outcome (LevelSet Max) :| [])
    , ("path", outcome (PlanDone "/notes/r7f2/plan.md") :| [])
    ,
        ( "draft"
        , outcome (DraftDone (DraftPr pr (Branch "main") (Branch "feature"))) :| []
        )
    ,
        ( "commit"
        , outcome (ImplementDone (Commit sha (Set.fromList [minBound ..]))) :| []
        )
    , ("head", outcome (ReviewRows sha) :| [])
    ,
        ( "picks"
        , outcome
            ( PickLoop
                ( Picks
                    (Set.fromList [Label "A", Label "B"])
                    ( Map.fromList
                        [ (Requirement "R1", Met)
                        , (Requirement "R2", NotMet)
                        , (Requirement "R3", Unverified)
                        ]
                    )
                )
            )
            :| [outcome (PickFinal (Picks Set.empty Map.empty))]
        )
    , ("failing", outcome (AwaitCiRed sha (Check "lint" :| [Check "test"])) :| [])
    , ("url", outcome (TicketWritten ticket) :| [])
    , ("branch", outcome (OpenBranchDone (Branch "feature")) :| [])
    , ("note", outcome (DirectDone "renamed the README's title") :| [])
    ,
        ( "tasks"
        , outcome (BreakdownDone engineers (tasksOf (plainTask "t1" [] :| [everyKey])))
            :| []
        )
    ]
  where
    sha = Sha "0123456789abcdef0123456789abcdef01234567"

pr :: Url
pr = Url "https://github.com/o/r/pull/7"

ticket :: Url
ticket = Url "https://github.com/o/r/issues/3"

-- | A task that writes every key a task has, its tagged shape a round's.
everyKey :: Task
everyKey =
    (plainTask "t2" ["t1"])
        { fuel = Max
        , qa = True
        , heavy = True
        , security = Set.fromList [minBound ..]
        , shape = RoundOn pr
        , plan = ParentDecided
        , repo = Just (Repo "o" "r")
        , worktree = shellPath "/wt/t2"
        , Artifact.flow = TenXFlow
        }

-- | #360's example line.
reviewRows :: Envelope
reviewRows =
    Envelope
        { source = Cli
        , seq = 12
        , ts = UTCTime (fromGregorian 2026 11 12) 36000
        , run = runId "r7f2"
        , head = Just (Sha "0123456789abcdef0123456789abcdef01234567")
        , session = Nothing
        , event = stepTook (ReviewRows (Sha "abc123"))
        }

-- | Picks of row A, with R1 met.
picked :: Envelope
picked =
    reviewRows
        { event =
            stepTook
                ( PickLoop
                    (Picks (Set.singleton (Label "A")) (Map.singleton (Requirement "R1") Met))
                )
        }

metR1 :: Text
metR1 = "{\"requirement\":\"R1\",\"outcome\":\"met\"}"

-- | The chief's picks of a route and of a block.
chiefPicks :: [Envelope]
chiefPicks =
    [ reviewRows {event = Took mempty (pickOf "route" "engineer")}
    , reviewRows {event = Took mempty (pickOf "block" "shipping")}
    ]

-- | A dumped void, reason @r@, of the seq this JSON number spells.
voidingSeq :: Text -> Text
voidingSeq n =
    encodeLine reviewRows {event = Voided 7 "r"}
        `replacing` ("\"seq\":7", "\"seq\":" <> n)

-- | A started line naming parent run r7f2.
parentRun :: Envelope
parentRun =
    reviewRows
        { event =
            Started
                ( Start
                    EngineerFlow
                    "notes"
                    ( ByRole
                        (Parent (runId "r7f2") (InFan (Tasked (TaskId "t1"))))
                        OwnPr
                        ChildConfirms
                    )
                    mempty
                    Nothing
                    (absolutePath "/work")
                    Nothing
                )
        }

-- | An envelope's row as @state dump@ prints it.
encodeLine :: Envelope -> Text
encodeLine = dumpLine . eventRow

-- | A dumped row read back: its envelope, or the row this kernel does not read.
decodeLine :: Text -> Either Decoded Envelope
decodeLine raw =
    either (error . ("not a dumped row: " <>)) (known . decodeRow shipped) $
        Aeson.eitherDecodeStrictText raw >>= parseEither (withObject "row" rowOf)
  where
    rowOf o =
        EventRow
            <$> o .: "run_id"
            <*> o .: "seq"
            <*> o .: "schema_version"
            <*> o .: "type"
            <*> o .: "time"
            <*> o .: "session_id"
            <*> o .: "head_sha"
            <*> o .: "hook_digest"
            <*> (jsonText <$> o .: "data")

malformed :: Either Decoded a -> Bool
malformed = \case
    Left (Unknown _) -> True
    Left (Retired _) -> False
    Left (Known _) -> False
    Right _ -> False

-- | A row as any writer could leave it: a real one, any column changed.
genAnyRow :: Gen EventRow
genAnyRow = do
    row <- eventRow <$> genEnvelope
    kind <- Gen.element [row.eventType, "no_such_event", "legacy.note", "refusal"]
    version <- Gen.element [row.schemaVersion, 0, 2, maxBound]
    payload <- Gen.element [row.payload, "{}", "not json", "{\"message\":1}"]
    n <- Gen.element [row.seq, -1, 0]
    time <- Gen.element [row.time, "yesterday"]
    digest <- Gen.element [row.hookDigest, Just "XYZ", Just (Text.replicate 16 "0")]
    pure
        row
            { Row.eventType = kind
            , Row.schemaVersion = version
            , Row.payload = payload
            , Row.seq = n
            , Row.time = time
            , Row.hookDigest = digest
            }
