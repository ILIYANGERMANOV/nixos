module State.Cli.ShellSpec (spec) where

import Data.List (nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Effects.Store.Connection (Durability (..))
import Hedgehog (Gen, annotateShow, cover, forAll, forAllWith, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Numeric.Natural (Natural)
import State.Category.Fuel (Fuel (Balanced))
import State.Cli.Command (Command (OnRun), RunCommand (Record), parseCommand)
import State.Cli.Shell (recordedEvent, storeDurability)
import State.Run.Codec (taskIdText)
import State.Run.Event
import State.Run.Event qualified as Event (Start (..))
import State.Run.EventGen (
    bareGap,
    fuelSet,
    genTasks,
    ijson,
    logOf,
    runId,
    start,
    stopgapKey,
    tasksOf,
    titled,
 )
import State.Run.Fold (RunState, replay)
import State.Run.RunGen (childOf, loadSteps, plainTask, taskFileJson, tenXGraph)
import State.Run.Stopgap (StopgapAt (..))
import State.Step.Fan (Outcome (BreakdownDone), engineers)
import State.Table (Steps)
import Test.Hspec (Spec, describe, it, runIO, shouldBe)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Cli.Shell" $ do
    steps <- runIO loadSteps
    it
        "keeps the store fully synced unless argv opens with --store-durability unsynced"
        $ do
            storeDurability ["next"] `shouldBe` (Full, ["next"])
            storeDurability ["next", "--store-durability", "unsynced"]
                `shouldBe` (Full, ["next", "--store-durability", "unsynced"])
            storeDurability ["--store-durability", "unsynced", "next"]
                `shouldBe` (Unsynced, ["next"])

    it
        "names, on every task event it records, the breakdown the run holds the task in"
        . hedgehog
        $ do
            tasks <- forAll genTasks
            gaps <- forAll (Gen.int (Range.linear 0 4))
            again <- forAll Gen.bool
            let broken = stepTook (BreakdownDone engineers tasks)
                -- Each epic a base names is opened before the breakdown.
                opens =
                    [ EpicMoved epic (Opens (Repo "o" "r") (Branch "epic"))
                    | epic <- nub [epic | OnEpic epic <- map (.base) (taskList tasks)]
                    ]
                -- The first breakdown's seq: the start is seq 0, then the Fuel, the epics, the gaps and the override.
                first = fromIntegral (gaps + length opens + 3)
                -- A second breakdown, with no agent at work, starts a fresh fan-out.
                newest = if again then first + 2 else first
                state =
                    replayed
                        ( [fuelSet Balanced]
                            <> opens
                            <> replicate gaps (Gapped (bareGap "a gap"))
                            <> [Overridden (StateName "breakdown") "agreed", broken]
                            <> concat [[Overridden (StateName "breakdown") "re-plan", broken] | again]
                        )
            task <- forAll (Gen.element (map (.id) (taskList tasks)))
            (words', file, expected) <-
                forAllWith (\(w, _, _) -> show w) (genRecording task)
            cover 10 "a second breakdown" again
            annotateShow newest
            recordedIn steps state file words' === Just (expected newest)

    it "copies a resumed child's task from its spawned" $
        recordedIn
            steps
            ( replayed
                [ fuelSet Balanced
                , Overridden (StateName "breakdown") "agreed"
                , stepTook (BreakdownDone engineers (tasksOf (plainTask "t1" [] :| [])))
                , Spawned (childOf "c1" "t1")
                ]
            )
            Nothing
            ["resumed", "c1"]
            `shouldBe` Just (Resumed (runId "c1") (Just (TaskRef (TaskId "t1") 1)))

-- | A 10x run of these events after its start, at seq 0.
replayed :: [Event] -> RunState
replayed events =
    either
        (error . show)
        id
        (replay tenXGraph (logOf (Started start {Event.flow = TenXFlow} :| events)))

-- | The event @state record <words>@ appends, the file it reads holding this text; none when refused.
recordedIn :: Steps -> RunState -> Maybe Text -> [Text] -> Maybe Event
recordedIn steps state file words' = case parseCommand steps ("record" : words') of
    Right (_, Right (OnRun (Record recording))) ->
        either
            (const Nothing)
            Just
            (recordedEvent tenXGraph state Nothing file 99 recording)
    _ -> Nothing

{- | A recording naming the task, the file it reads, and the event it
writes given the seq of the breakdown that holds the task.
-}
genRecording :: TaskId -> Gen ([Text], Maybe Text, Natural -> Event)
genRecording task =
    Gen.element
        [ (["spawning", name], Nothing, Spawning . ref)
        , (["held", name, url], Nothing, \n -> Held (ref n) (Url url))
        , (["acted", name, url], Nothing, \n -> ActedOn (ref n) (Url url))
        ,
            ( ["task", name, "merged", url]
            , Nothing
            , \n -> TaskMoved (ref n) (Merged (Url url))
            )
        ,
            ( ["task", name, "parked", "not", "needed"]
            , Nothing
            , \n -> TaskMoved (ref n) (Parked "not needed" Nothing)
            )
        , (["task", "add", "fix.json"], Just (taskFileJson fix), (`TaskAdded` fix))
        , (["task", "head", name, sha], Nothing, \n -> TaskHead (ref n) (Sha sha))
        ,
            ( ["task", name, "delivered", url]
            , Nothing
            , \n -> TaskMoved (ref n) (Delivered (Url url))
            )
        ,
            ( ["task", name, "base", "on_default", "--reason", "restack"]
            , Nothing
            , \n -> TaskBaseChanged (ref n) OnDefault (titled "restack") DepsKept
            )
        ,
            ( ["user_needed", "add", "the", "key", "--blocks", name]
            , Nothing
            , \n -> UserNeeded (Need (titled "add the key") (Set.singleton (ref n)) Nothing)
            )
        ,
            ( ["stopgap", "deploy.window", "1", "--task", name, "--reason", "restack"]
            , Nothing
            , \n ->
                StopgapSet
                    (StopgapAt (Just (ref n)) (stopgapKey "deploy.window"))
                    (ijson "1")
                    (titled "restack")
            )
        ]
  where
    sha = Text.replicate 4 "0123456789"
    name = taskIdText task
    ref = TaskRef task
    url = "https://github.com/o/r/pull/1"
    fix = plainTask "fix" []
