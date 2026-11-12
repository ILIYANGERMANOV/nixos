module State.Flows.TenXSpec (spec) where

import Data.Either (isRight)
import State.Flows.TenX (tenX)
import State.Graph (graph)
import Test.Hspec (Spec, describe, it, shouldSatisfy)

{- No Keep test here: the steps it keeps run inside each engineer, whose own
spec holds them, and the engineers' fan-out is no endo, so no 'Opt' can mark it.
-}
spec :: Spec
spec = describe "State.Flows.TenX" $ do
    it "builds: no state has two edges on one event, no loop id is used twice" $
        graph tenX `shouldSatisfy` isRight
