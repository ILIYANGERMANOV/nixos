module State.Flow.Role.ChiefSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import State.Category.Graph (OpenGraph (..), Place (..))
import State.Category.Step (
    EventName (..),
    OutcomeName (..),
    SomeStep (..),
    StepSet (stepName),
    stateNameText,
 )
import State.Role (drawnOutcomes, isPick)
import State.Run.RunGen (chiefGraph)
import State.Step.Catalog (
    AnyOutcome (..),
    AnyStep (..),
    Layer (PickLayer),
    allSteps,
    outcomeEvent,
 )
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec =
    describe "State.Flow.Role.Chief" $ do
        it
            "names no pick as any step is named, so a pick's event never reads as a step's"
            $ Set.intersection (Set.map fst decodedPicks) stepNames `shouldBe` Set.empty
        it "reads every pick and label the chief draws, so the log decodes each pick" $
            drawnPicks `shouldBe` decodedPicks
  where
    decodedPicks =
        Set.fromList
            [ (stateNameText event.step, label)
            | AnyOutcome PickLayer some <- drawnOutcomes
            , let event = outcomeEvent (AnyOutcome PickLayer some)
            , OutcomeName label <- [event.outcome]
            ]
    stepNames =
        Set.fromList [stateNameText (stepName s) | AnyStep _ (SomeStep s) <- allSteps]
    drawnPicks =
        Set.fromList
            [ (stateNameText hub.name, label)
            | (hub, name) <- Map.keys chiefGraph.edges
            , isPick hub.name
            , OutcomeName label <- [name.outcome]
            ]
