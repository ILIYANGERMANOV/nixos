{-# OPTIONS_GHC -fdefer-type-errors -Wno-deferred-type-errors #-}

{- | Typed gluing and typed outcomes, checked the only way a test can: each term below is
ill-typed, compiled here with its type error deferred to run time, and the
test sees that error raised. Nothing else lives in this module, so the
deferral hides no real mistake.
-}
module State.Category.FlowSpec (spec) where

import Control.Exception (TypeError (..), evaluate, try)
import Data.List (isInfixOf)
import Data.Set qualified as Set
import State.Category.Flow (FanId (..), Flow (..), LoopId (..), OnEmpty (..), OptId (..))
import State.Category.Graph (graph)
import State.Category.Step (Leg (..), Outcome, Sing, outcomeEvent, packed)
import State.Step.Artifact (Commit (..), Sha (..))
import State.Step.Build (Sing (..))
import State.Step.Fan (Sing (..))
import State.Step.Gather (Sing (..))
import State.Step.Plan (Sing (..))
import State.Step.Review (Outcome (..), Sing (..))
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it)

spec :: Spec
spec = describe "State.Category.Flow" $ do
    describe "ill_typed_terms_do_not_compile" $ do
        it "a block whose out is not the next block's in" $
            rejected
                "Couldn't match type ‘State.Category.Ty.Ctx’ with ‘State.Category.Ty.Diff’"
                (Do Implement :> Do Research)

        it "an optional step that changes the type" $
            rejected
                "Couldn't match type ‘State.Category.Ty.Diff’ with ‘State.Category.Ty.Plan’"
                (Opt ORefactor (Do Implement))

        it "an optional step with an exit" $
            rejected
                "Couldn't match type: Just State.Category.Ty.Plan with: Nothing"
                (Opt OAlt (Do Confirm))

        it "a loop whose body never exits" $
            rejected
                "Couldn't match type: Nothing with: Just State.Category.Ty.Diff"
                (Loop LReview ExitOut (Do Refactor))

        it "a loop that exits when empty to another type than its in" $
            rejected
                "Couldn't match type ‘State.Category.Ty.Plan’ with ‘State.Category.Ty.Ctx’"
                (Loop LPlan ExitOut (Do PlanS :> Do Confirm))

        it "a series whose two sides exit with different types" $
            rejected
                "Both sides of :> exit, with different types: State.Category.Ty.Ctx and State.Category.Ty.Plan"
                (Loop LPlan StopOut (Do Interview :> Do PlanS :> Do Confirm))

        it "a fan-out's state drawn as a step" $
            rejected
                "A fan-out's state is drawn by Par, not Do"
                (Do (FanOut FEngineers))

    describe "ill_typed_outcomes_do_not_compile" $ do
        it "an exit of a step with none" $
            rejectedShown
                "Outcome leg Exited does not fit step signature '(State.Category.Ty.Diff, Nothing, State.Category.Ty.Diff)"
                (outcomeEvent (packed Fix (by @'Exited Fix)))

        it "a skip of a step with an exit" $
            rejectedShown
                "Outcome leg Skipped does not fit step signature '(State.Category.Ty.Diff, Just State.Category.Ty.Diff, State.Category.Ty.Diff)"
                (outcomeEvent (packed Review (by @'Skipped Review)))

        it "a skip of a step that changes the type" $
            rejectedShown
                "Couldn't match type ‘State.Category.Ty.Plan’ with ‘State.Category.Ty.Diff’"
                (outcomeEvent (packed Implement (by @'Skipped Implement)))

        it "an outcome packed as another step's" $
            rejectedShown
                "Couldn't match type ‘State.Step.Review.Fix’ with ‘State.Step.Review.Review’"
                (outcomeEvent (packed Review (FixDone (Commit (Sha "") Set.empty))))

{- | The deferred error fires when the term is built, which 'graph' forces.
The trivial constraint keeps GHC from binding the error outside the term,
where it would fire as the spec is built (the trick of should-not-typecheck).
The fragment is part of GHC's headline, so an unrelated error does not pass;
the lines after it quote the call, fragment included, so they are left out.
-}
rejected :: String -> ((() ~ ()) => Flow i e o) -> Expectation
rejected fragment term = rejectedShown fragment (graph term)

-- | An outcome of this step by this leg, which no constructor need declare: the test never forces it.
by :: forall l k (s :: k). Sing s -> Outcome s l
by _ = error "never forced"

-- | As 'rejected', for any term 'show' forces: an outcome's event forces its leg.
rejectedShown :: (Show a) => String -> ((() ~ ()) => a) -> Expectation
rejectedShown fragment term =
    try (evaluate (length (show term))) >>= \case
        Left (TypeError message)
            | fragment `isInfixOf` headline message -> pure ()
            | otherwise -> expectationFailure ("another type error:\n" <> message)
        Right _ -> expectationFailure "the term type-checked"

-- | Its words one space apart: GHC wraps a long type over lines.
headline :: String -> String
headline = unwords . concatMap words . takeWhile (not . ("In the " `isInfixOf`)) . lines
