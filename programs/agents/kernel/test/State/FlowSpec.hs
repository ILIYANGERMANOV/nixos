{-# OPTIONS_GHC -fdefer-type-errors -Wno-deferred-type-errors #-}

{- | Typed gluing, checked the only way a test can: each term below is
ill-typed, compiled here with its type error deferred to run time, and the
test sees that error raised. Nothing else lives in this module, so the
deferral hides no real mistake.
-}
module State.FlowSpec (spec) where

import Control.Exception (TypeError (..), evaluate, try)
import Data.List (isInfixOf)
import State.Cap (Step (..))
import State.Flow (Flow (..), LoopId (..), OnEmpty (..), OptId (..))
import State.Graph (graph)
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it)

spec :: Spec
spec = describe "State.Flow" $ do
    describe "ill_typed_terms_do_not_compile" $ do
        it "a block whose out is not the next block's in" $
            rejected
                "Expected: Step State.Cap.Diff Nothing State.Cap.Ctx"
                (Do Implement :> Do Research)

        it "an optional step that changes the type" $
            rejected
                "Expected: Step State.Cap.Plan Nothing State.Cap.Plan"
                (Opt ORefactor (Do Implement))

        it "an optional step with an exit" $
            rejected
                "Expected: Step State.Cap.Plan Nothing State.Cap.Plan"
                (Opt OAlt (Do Confirm))

        it "a loop whose body never exits" $
            rejected
                "Expected: Step State.Cap.Diff (Just State.Cap.Diff) State.Cap.Diff"
                (Loop LReview ExitOut (Do Refactor))

        it "a loop that exits when empty to another type than its in" $
            rejected
                "Expected: Step State.Cap.Plan (Just State.Cap.Plan) State.Cap.Plan"
                (Loop LPlan ExitOut (Do PlanS :> Do Confirm))

        it "a series whose two sides exit with different types" $
            rejected
                "Both sides of :> exit, with different types: State.Cap.Ctx and State.Cap.Plan"
                (Loop LPlan StopOut (Do Interview :> Do PlanS :> Do Confirm))

{- | The deferred error fires when the term is built, which 'graph' forces.
The trivial constraint keeps GHC from binding the error outside the term,
where it would fire as the spec is built (the trick of should-not-typecheck).
The fragment is part of GHC's headline, so an unrelated error does not pass;
the lines after it quote the call, fragment included, so they are left out.
-}
rejected :: String -> ((() ~ ()) => Flow i e o) -> Expectation
rejected fragment term =
    try (evaluate (length (show (graph term)))) >>= \case
        Left (TypeError message)
            | fragment `isInfixOf` headline message -> pure ()
            | otherwise -> expectationFailure ("another type error:\n" <> message)
        Right _ -> expectationFailure "the term type-checked"

headline :: String -> String
headline = unlines . takeWhile (not . ("In the " `isInfixOf`)) . lines
