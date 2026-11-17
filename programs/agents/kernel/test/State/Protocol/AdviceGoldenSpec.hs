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
import State.Protocol.Advice (Facts (..), advise)
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

-- | The run moved to each state of the graph in turn, and the advice there.
everyState :: Steps -> OpenGraph -> RunState -> Text
everyState steps flowGraph run =
    Text.unlines
        [ stateNameText (placeName place) <> ": " <> Text.pack (show (advise steps flowGraph noFacts run {at = At place}))
        | place <- Set.toList (places flowGraph)
        ]
  where
    noFacts = Facts Nothing Nothing []
