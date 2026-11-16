module State.Run.CodecSpec (spec) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..))
import Data.Time.Calendar (fromGregorian)
import Hedgehog (Gen, forAll, tripping)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import State.Category.Fuel (Fuel (Low))
import State.Run.Ask (Basis (..), Proposal (..), QId (..))
import State.Run.Codec (LineError (..), LogError (..), decodeBreakdown, decodeLine, decodeLog, decodeTask, encodeLine)
import State.Run.Event (Digest (..), Envelope (..), Event (..), EventId (..), FlowName (..), Judgement (..), Label (..), Parent (..), Picks (..), Principal (..), Repo (..), Requirement (..), Said (..), Sha (..), Shape (..), Source (..), Start (..), Stop (..), StopReason (..), Task (..), TaskId (..), parseRunId, stepTook, taskList, tookIn)
import State.Run.EventGen (genEnvelope, oneLine, runId, tasksOf)
import State.Run.RunGen (breakdownJson, plainTask, roundTask, securityScope, taskFileJson)
import State.Step.Artifact (shellPath)
import State.Step.Artifact qualified as Artifact (Task (..))
import State.Step.Fan (Outcome (..), engineers)
import State.Step.Review (Outcome (..))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Run.Codec" $ do
    it "codec_round_trips" . hedgehog $ do
        envelope <- forAll genEnvelope
        tripping envelope encodeLine decodeLine

    it "writes the line #360 documents, keys in its order" $
        encodeLine reviewRows
            `shouldBe` "{\"v\":4,\"id\":\"r7f2:12\",\"seq\":12,\"ts\":\"2026-11-12T10:00:00Z\",\"run\":\"r7f2\",\"head\":\"abc123\",\"session\":null,\"type\":\"review.rows\",\"data\":{\"head\":\"abc123\"}}"

    it "refuses a version 1 log, the Python state's with no version" $
        decodeLine pythonV1 `shouldBe` Left (Unsupported 1)

    it "refuses a version 2 log, the Python state's" $
        decodeLine pythonV2 `shouldBe` Left (Unsupported 2)

    it "refuses a version 3 log, an earlier kernel's" $
        decodeLine (encodeLine reviewRows `replacing` ("\"v\":4", "\"v\":3")) `shouldBe` Left (Unsupported 3)

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

    it "reads a step's outcome inside a scope under its qualified type" $
        decodeLine (encodeLine reviewRows `replacing` ("\"type\":\"review.rows\"", "\"type\":\"security/review.rows\""))
            `shouldBe` Right reviewRows {event = tookIn securityScope (ReviewRows (Sha "abc123"))}

    it "refuses a run's event inside a scope: only a step's outcome is named so" $
        decodeLine (encodeLine reviewRows {event = FuelSet Low} `replacing` ("\"type\":\"fuel\"", "\"type\":\"security/fuel\"")) `shouldSatisfy` malformed

    it "refuses a red CI result with no failing check" $
        decodeLine (encodeLine reviewRows `replacing` ("review.rows", "await_ci.red") `replacing` ("{\"head\":\"abc123\"}", "{\"head\":\"abc123\",\"failing\":[]}"))
            `shouldSatisfy` malformed

    it "refuses picks naming a row twice" $
        decodeLine (encodeLine picked `replacing` ("\"rows\":[\"A\"]", "\"rows\":[\"A\",\"A\"]")) `shouldSatisfy` malformed

    it "writes a ruling's answer, why, cost and basis under the question's id" $
        encodeLine reviewRows {event = RuledOn (QId (runId "c1") 3) (Proposal (oneLine "v2") (oneLine "the docs say so") (oneLine "an hour") (Just (AnsweredBy (Numbered (runId "r7f2") 4))))}
            `shouldBe` "{\"v\":4,\"id\":\"r7f2:12\",\"seq\":12,\"ts\":\"2026-11-12T10:00:00Z\",\"run\":\"r7f2\",\"head\":\"abc123\",\"session\":null,\"type\":\"ruled\",\"data\":{\"qid\":\"c1:3\",\"answer\":\"v2\",\"why\":\"the docs say so\",\"cost\":\"an hour\",\"basis\":{\"event\":\"r7f2:4\"}}}"

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

    it "reads a task file as a breakdown spells each task" $
        decodeTask (taskFileJson (plainTask "fix" ["t1"])) `shouldBe` Right (plainTask "fix" ["t1"])

    it "reads a round task's existing PR from its pr key" $
        decodeTask (taskFileJson (roundTask "t1" "https://pr/1")) `shouldBe` Right (roundTask "t1" "https://pr/1")

    it "reads a task's repo and worktree, each without the other" $
        map
            (\task -> decodeTask (taskFileJson task) == Right task)
            [placed, placed {worktree = Nothing}, placed {repo = Nothing}]
            `shouldBe` [True, True, True]

    it "writes no repo, worktree or flow key for an engineer's task the breakdown places nowhere" $
        encodeLine reviewRows {event = stepTook (BreakdownDone engineers (tasksOf (plainTask "t1" [] :| [])))}
            `shouldSatisfy` (\line -> not (any (`Text.isInfixOf` line) ["\"repo\"", "\"worktree\"", "\"flow\""]))

    it "reads a task's flow, an engineer's where the task names none, as a breakdown older than flows" $
        map (fmap (.flow) . decodeTask . taskFileJson) [ledBy10x, plainTask "t1" []] `shouldBe` [Right TenXFlow, Right EngineerFlow]

    it "writes a 10x task's flow under the key a breakdown names it by" $
        encodeLine reviewRows {event = stepTook (BreakdownDone engineers (tasksOf (ledBy10x :| [])))} `shouldSatisfy` Text.isInfixOf "\"flow\":\"10x\""

    it "refuses a task's flow no role leads" $
        decodeTask (taskFileJson ledBy10x `replacing` ("\"10x\"", "\"chief\"")) `shouldBe` Left "Error in $: unknown flow \"chief\""

    it "refuses a repo not OWNER/REPO of shell-inert characters" $
        [decodeTask (taskFileJson placed `replacing` ("\"o/r\"", hostile)) | hostile <- ["\"o/r/x\"", "\"/r\"", "\"o /r\"", "\"o;x/r\"", "\"o/$(x)\"", "\"o/r|x\"", "\"o/\\u00e9\""]]
            `shouldBe` map
                (\raw -> Left ("Error in $: unknown repo " <> raw))
                ["\"o/r/x\"", "\"/r\"", "\"o /r\"", "\"o;x/r\"", "\"o/$(x)\"", "\"o/r|x\"", "\"o/\\233\""]

    it "refuses a worktree not absolute or of characters a shell reads" $ do
        let hostile = ["\"wt\"", "\"/w t\"", "\"/w;x\"", "\"/w$(x)\"", "\"/w`x`\"", "\"/w|x\""]
        map (\raw -> decodeTask (taskFileJson placed `replacing` ("\"/wt\"", raw))) hostile
            `shouldBe` map (\raw -> Left ("Error in $: a worktree is an absolute path of ASCII letters, digits and ._/@+-, not " <> raw)) hostile

    it "refuses a malformed task file as the breakdown's decoder does" $
        map decodeTask ["[]", taskFileJson (plainTask "fix" []) `replacing` ("\"fuel\":\"balanced\"", "\"fuel\":\"huge\"")]
            `shouldBe` [Left "Error in $: parsing task failed, expected Object, but encountered Array", Left "Error in $: unknown fuel \"huge\""]

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
        , event = stepTook (ReviewRows (Sha "abc123"))
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
picked = reviewRows {event = stepTook (PickLoop (Picks (Set.singleton (Label "A")) (Map.singleton (Requirement "R1") Met)))}

metR1 :: Text
metR1 = "{\"requirement\":\"R1\",\"outcome\":\"met\"}"

-- | A started line naming parent run r7f2.
parentRun :: Envelope
parentRun = reviewRows {event = Started (Start EngineerFlow "notes" (ByRole (Parent (runId "r7f2") "/p/events.jsonl" (TaskId "t1")) OwnPr) mempty)}

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

-- | A task whose child runs the 10x flow.
ledBy10x :: Task
ledBy10x = (plainTask "t1" []) {Artifact.flow = TenXFlow}

-- | A task whose breakdown names its repo and worktree.
placed :: Task
placed = (plainTask "t1" []) {repo = Just (Repo "o" "r"), worktree = shellPath "/wt"}
