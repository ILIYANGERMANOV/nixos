{- | The advice at every state of the engineer and 10x flows, pinned as
main printed it: a change to the kernel's algebra (such as the Route) must
leave what @state next@ tells an agent in these flows as it was.
-}
module State.Protocol.AdviceGoldenSpec (spec) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import State.Category.Fuel (Fuel (..))
import State.Category.Graph (Node (..), OpenGraph, placeName, places)
import State.Category.Step (stateNameText)
import State.Golden (golden)
import State.Protocol.Advice (Advice (action, facts, prompt), Facts (..), advise, deliver, deliverMore, deliverPrompt, explained, skippable)
import State.Run.Event (Event (..))
import State.Run.Fold (RunState (..))
import State.Run.RunGen (g, loadSteps, plainTask, runAt, tenXAt, tenXGraph)
import State.Table (Steps)
import Test.Hspec (Spec, describe, it, runIO)

spec :: Spec
spec = describe "the advice at every state" $ do
    steps <- runIO loadSteps
    it "of the engineer, at each Fuel, is as main printed it" $
        golden "advice/engineer.txt" (Text.unlines [everyState steps g (runAt [FuelSet fuel]) | fuel <- [Low, Balanced, Max]])
    it "of the 10x, at its fan-out of two tasks, is as main printed it" $
        golden "advice/10x.txt" (everyState steps tenXGraph (tenXAt (plainTask "t1" [] :| [plainTask "t2" ["t1"]]) []))

-- | The run moved to each state of the graph in turn, and what @state next@ prints there.
everyState :: Steps -> OpenGraph -> RunState -> Text
everyState steps flowGraph run =
    Text.unlines
        [ "== " <> stateNameText (placeName place) <> "\n" <> printed flowGraph moved (advise steps flowGraph noFacts moved)
        | place <- Set.toList (places flowGraph)
        , let moved = run {at = At place}
        ]
  where
    noFacts = Facts Nothing Nothing []

{- | The advice as @state next@ prints it, less what only a live run adds: the
events it records, its refusals and its unsynced PR notes.
-}
printed :: OpenGraph -> RunState -> Advice -> Text
printed flowGraph run advice =
    Text.unlines
        ( deliver run.start advice.action
            : deliverMore run.start advice
                <> ["  " <> line | line <- explained run.start advice <> advice.facts <> skippable flowGraph run]
                <> [deliverPrompt run.start advice | not (Text.null advice.prompt)]
        )
