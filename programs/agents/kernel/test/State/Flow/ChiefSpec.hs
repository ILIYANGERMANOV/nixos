module State.Flow.ChiefSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import State.Category.Flow (nameText, unqualify)
import State.Category.Graph (Arrow (..), Edge (..), OpenGraph (..), placeName)
import State.Category.Step (EventName (..), OutcomeName (..), SomeStep (..), StepSet (stepName), stateNameText)
import State.Run.RunGen (chiefGraph, flowGraph)
import State.Step.Catalog (AnyStep (..), allSteps)
import State.Step.Choice (choices, routes)
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec =
    describe "State.Flow.Chief" $ do
        it "names no route nor branch as any choice, step, loop or skip is named, so a pick never reads as one of them" $
            Set.intersection routeNames otherNames `shouldBe` Set.empty
        it "lists every route and branch the chief draws, so the log decodes each pick" $
            drawnPicks `shouldBe` listedPicks
  where
    routeNames = Set.fromList (concat [nameText route : [branch | OutcomeName branch <- branches] | (route, branches) <- routes])
    otherNames = Set.fromList (map nameText choices <> [stateNameText (stepName s) | AnyStep _ (SomeStep s) <- allSteps] <> concatMap loopsAndSkips [minBound .. maxBound])
    loopsAndSkips flow =
        let drawn = flowGraph flow
         in map (bare . nameText) (Map.keys drawn.loops) <> [bare (nameText skip) | Edge {arrow = Skip skip _} <- Map.elems drawn.edges]
    bare :: Text -> Text
    bare = snd . unqualify
    listedPicks = Set.fromList [(nameText route, branch) | (route, branches) <- routes, branch <- branches]
    drawnPicks = Set.fromList [(stateNameText (placeName hub), name.outcome) | (hub, name) <- Map.keys chiefGraph.edges, Set.member hub chiefGraph.routes]
