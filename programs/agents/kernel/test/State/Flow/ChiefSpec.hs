module State.Flow.ChiefSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import State.Category.Flow (nameText, unqualify)
import State.Category.Graph (OpenGraph (..), Place (..), placeName)
import State.Category.Step (EventName (..), OutcomeName (..), SomeStep (..), StepSet (stepName), stateNameText)
import State.Flow.Drawn (drawnOutcomes, isPick)
import State.Run.RunGen (chiefGraph, flowGraph)
import State.Step.Catalog (AnyOutcome (..), AnyStep (..), Layer (PickLayer), allSteps, outcomeEvent)
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec =
    describe "State.Flow.Chief" $ do
        it "names no pick nor label as any step, loop or skip is named, so a pick never reads as one of them" $
            Set.intersection pickNames otherNames `shouldBe` Set.empty
        it "reads every pick and label the chief draws, so the log decodes each pick" $
            drawnPicks `shouldBe` decodedPicks
  where
    decodedPicks = Set.fromList [(stateNameText event.step, label) | AnyOutcome PickLayer some <- drawnOutcomes, let event = outcomeEvent (AnyOutcome PickLayer some), OutcomeName label <- [event.outcome]]
    pickNames = Set.fromList (concat [[pick, label] | (pick, label) <- Set.toList decodedPicks])
    otherNames = Set.fromList ([stateNameText (stepName s) | AnyStep _ (SomeStep s) <- allSteps] <> concatMap loopsAndSkips [minBound .. maxBound])
    loopsAndSkips flow =
        let drawn = flowGraph flow
         in map (bare . nameText) (Map.keys drawn.loops)
    bare :: Text -> Text
    bare = snd . unqualify
    drawnPicks = Set.fromList [(stateNameText (placeName hub), label) | (hub, name) <- Map.keys chiefGraph.edges, isPick hub.name, OutcomeName label <- [name.outcome]]
