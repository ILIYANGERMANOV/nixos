module State.CodecSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..))
import Data.Time.Calendar (fromGregorian)
import Hedgehog (Gen, forAll, tripping)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import State.Ask (Basis (..), Proposal (..), QId (..))
import State.Codec (LineError (..), LogError (..), decodeBreakdown, decodeLine, decodeLog, encodeLine)
import State.Event (Digest (..), Envelope (..), Event (..), EventId (..), FlowName (..), Judgement (..), Label (..), Outcome (..), Parent (..), Picks (..), Principal (..), Requirement (..), Said (..), Sha (..), Source (..), Start (..), Stop (..), StopReason (..), Task (..), TaskId (..), parseRunId, taskList)
import State.EventGen (genEnvelope, oneLine, runId)
import State.RunGen (breakdownJson, plainTask)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Codec" $ do
    it "codec_round_trips" . hedgehog $ do
        envelope <- forAll genEnvelope
        tripping envelope encodeLine decodeLine

    it "writes the line #360 documents, keys in its order" $
        encodeLine reviewRows
            `shouldBe` "{\"v\":3,\"id\":\"r7f2:12\",\"seq\":12,\"ts\":\"2026-11-12T10:00:00Z\",\"run\":\"r7f2\",\"head\":\"abc123\",\"session\":null,\"type\":\"review.rows\",\"data\":{\"head\":\"abc123\"}}"

    it "refuses a version 1 log, the Python state's with no version" $
        decodeLine pythonV1 `shouldBe` Left (Unsupported 1)

    it "refuses a version 2 log, the Python state's" $
        decodeLine pythonV2 `shouldBe` Left (Unsupported 2)

    it "refuses an unknown version" $
        decodeLine (encodeLine reviewRows `replacing` ("\"v\":3", "\"v\":4")) `shouldBe` Left (Unsupported 4)

    it "names the first line of a log it does not read" $
        decodeLog (encodeLine reviewRows <> "\n" <> pythonV2 <> "\n") `shouldBe` Left (LogError 2 (Unsupported 2))

    it "reads a log line by line, its last newline ending the last line" $
        decodeLog (encodeLine reviewRows <> "\n" <> encodeLine reviewRows <> "\n") `shouldBe` Right [reviewRows, reviewRows]

    it "hook_and_cli_ids_never_collide" . hedgehog $ do
        hook <- forAll genCollidingHookLine
        tripping hook encodeLine decodeLine

    it "refuses a line of run h, whose CLI ids read as hook ids" $
        decodeLine (encodeLine reviewRows `replacing` ("r7f2", "h")) `shouldSatisfy` malformed

    it "refuses a parent run h" $
        decodeLine (encodeLine parentRun `replacing` ("\"run\":\"r7f2\",\"log\"", "\"run\":\"h\",\"log\"")) `shouldSatisfy` malformed

    it "refuses a CLI id that names another seq" $
        decodeLine (encodeLine reviewRows `replacing` ("r7f2:12", "r7f2:11")) `shouldSatisfy` malformed

    it "refuses an unknown event type" $
        decodeLine (encodeLine reviewRows `replacing` ("review.rows", "review.maybe")) `shouldSatisfy` malformed

    it "refuses a red CI result with no failing check" $
        decodeLine (encodeLine reviewRows `replacing` ("review.rows", "await_ci.red") `replacing` ("{\"head\":\"abc123\"}", "{\"head\":\"abc123\",\"failing\":[]}"))
            `shouldSatisfy` malformed

    it "refuses picks naming a row twice" $
        decodeLine (encodeLine picked `replacing` ("\"rows\":[\"A\"]", "\"rows\":[\"A\",\"A\"]")) `shouldSatisfy` malformed

    it "writes a ruling's answer, why, cost and basis under the question's id" $
        encodeLine reviewRows {event = RuledOn (QId (runId "c1") 3) (Proposal (oneLine "v2") (oneLine "the docs say so") (oneLine "an hour") (Just (AnsweredBy (Numbered (runId "r7f2") 4))))}
            `shouldBe` "{\"v\":3,\"id\":\"r7f2:12\",\"seq\":12,\"ts\":\"2026-11-12T10:00:00Z\",\"run\":\"r7f2\",\"head\":\"abc123\",\"session\":null,\"type\":\"ruled\",\"data\":{\"qid\":\"c1:3\",\"answer\":\"v2\",\"why\":\"the docs say so\",\"cost\":\"an hour\",\"basis\":{\"event\":\"r7f2:4\"}}}"

    it "refuses a ruling whose answer breaks the line" $
        decodeLine (encodeLine reviewRows {event = RuledOn (QId (runId "c1") 3) (Proposal (oneLine "v2") (oneLine "why") (oneLine "cost") Nothing)} `replacing` ("\"answer\":\"v2\"", "\"answer\":\"v2\\nREADY\""))
            `shouldSatisfy` malformed

    it "writes a child's stop as its reason, upper case, with its why as the ref" $
        encodeLine reviewRows {event = HandedBack (runId "c1") (Ended (Stop Blocked "no access"))}
            `shouldSatisfy` Text.isInfixOf "\"type\":\"handed_back\",\"data\":{\"child\":\"c1\",\"token\":\"BLOCKED\",\"ref\":\"no access\",\"qid\":null}"

    it "reads a breakdown's tasks in order" $
        map (.id) . taskList <$> decodeBreakdown (breakdownJson [plainTask "t1" [], plainTask "t2" ["t1"]]) `shouldBe` Right [TaskId "t1", TaskId "t2"]

    it "refuses a breakdown that is empty, names a task twice or depends on a later task" $
        map (either Left (const (Right ())) . decodeBreakdown . breakdownJson) [[], [plainTask "t1" [], plainTask "t1" []], [plainTask "t1" ["t2"], plainTask "t2" []]]
            `shouldBe` [ Left "Error in $: a breakdown has a task at least"
                       , Left "Error in $: task t1 is named twice"
                       , Left "Error in $: task t1 depends on t2, which is not an earlier task"
                       ]

    it "refuses a retag to any kind but Security" $
        decodeLine (encodeLine reviewRows {event = RetaggedSecurity (QId (runId "c1") 3)} `replacing` ("\"kind\":\"Security\"", "\"kind\":\"Design\""))
            `shouldSatisfy` malformed

    it "refuses picks judging a requirement twice" $
        decodeLine (encodeLine picked `replacing` (metR1, metR1 <> ",{\"requirement\":\"R1\",\"outcome\":\"not-met\"}")) `shouldSatisfy` malformed

-- | #360's example line.
reviewRows :: Envelope
reviewRows =
    Envelope
        { source = Cli
        , seq = 12
        , ts = UTCTime (fromGregorian 2026 11 12) 36000
        , run = runId "r7f2"
        , head = Just (Sha "abc123")
        , session = Nothing
        , event = Took (ReviewRows (Sha "abc123"))
        }

{- | A hook line of an accepted run id, drawn with its seq and digest from so
small a set that a hook id spelling a CLI id is likely, were "h" or a colon
allowed in a run id.
-}
genCollidingHookLine :: Gen Envelope
genCollidingHookLine = do
    run <- Gen.mapMaybe parseRunId (Gen.element ["h", "a", "h:a", "ha", "a:h", "h:"])
    n <- Gen.integral (Range.linear 0 2)
    digest <- Gen.element ["0", "1", "2", "a:0", "a:1", ":0"]
    pure reviewRows {source = Hook (Digest digest), seq = n, run}

-- | Picks of row A, with R1 met.
picked :: Envelope
picked = reviewRows {event = Took (PickLoop (Picks (Set.singleton (Label "A")) (Map.singleton (Requirement "R1") Met)))}

metR1 :: Text
metR1 = "{\"requirement\":\"R1\",\"outcome\":\"met\"}"

-- | A started line naming parent run r7f2.
parentRun :: Envelope
parentRun = reviewRows {event = Started (Start EngineerFlow "notes" (ByRole (Parent (runId "r7f2") "/p/events.jsonl" (TaskId "t1"))) mempty)}

-- | Lines in the shape the Python @state@ wrote, its other keys left out.
pythonV1, pythonV2 :: Text
pythonV1 = "{\"seq\":0,\"ts\":\"t\",\"head\":null,\"session\":null,\"event\":{\"type\":\"started\",\"notes\":\"n\"}}"
pythonV2 = "{\"seq\":0,\"ts\":\"t\",\"head\":null,\"session\":null,\"event\":{\"type\":\"started\",\"notes\":\"n\",\"version\":2}}"

replacing :: Text -> (Text, Text) -> Text
replacing whole (old, new) = Text.replace old new whole

malformed :: Either LineError a -> Bool
malformed = \case
    Left (Malformed _) -> True
    Left (Unsupported _) -> False
    Right _ -> False
