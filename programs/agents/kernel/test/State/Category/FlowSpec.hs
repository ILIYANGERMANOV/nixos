{-# LANGUAGE PartialTypeSignatures #-}
{-# OPTIONS_GHC -fdefer-type-errors -Wno-deferred-type-errors -Wno-partial-type-signatures #-}

{- | Typed gluing and typed outcomes, checked the only way a test can: each term below is
ill-typed, compiled here with its type error deferred to run time, and the
test sees that error raised. Nothing else lives in this module, so the
deferral hides no real mistake.
-}
module State.Category.FlowSpec (spec) where

import Control.Exception (TypeError (..), evaluate, try)
import Data.Char (isAlphaNum, isDigit)
import Data.List (isInfixOf)
import Data.Set qualified as Set
import State.Category.Flow (Branch (..), Branches (..), CapTarget (..), Flow (..))
import State.Category.Fuel (SkipWhen (..), always)
import State.Category.Graph (graph)
import State.Category.Meter (AtCap (..), Limit (..))
import State.Category.Step (Leg (..), Outcome, Sing, outcomeEvent, packed)
import State.Category.Ty qualified
import State.Flow.Library (opt)
import State.Flow.Triage (Sing (..))
import State.Role (SomeFlow (..), flowOut)
import State.Step.Artifact (Commit (..), Sha (..))
import State.Step.Build (Sing (..))
import State.Step.Fan (Sing (..), engineers)
import State.Step.Gather (Sing (..))
import State.Step.Plan (Sing (..))
import State.Step.Review (Outcome (..), Sing (..))
import State.Step.Ship (Sing (..))
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it)

spec :: Spec
spec = describe "State.Category.Flow" $ do
    describe "ill_typed_terms_do_not_compile" $ do
        it "a block whose out is not the next block's in" $
            rejected
                "Couldn't match type: State.Category.Ty.Ctx with: State.Category.Ty.Diff"
                (Do Implement :> Do Research)

        it "an optional step that changes the type" $
            rejected
                "Couldn't match type: State.Category.Ty.Diff with: State.Category.Ty.Plan"
                (opt "refactor" (always Never) (Do Implement))

        it "an optional step with an exit" $
            rejected
                "Couldn't match type: Just State.Category.Ty.Plan with: Nothing"
                (opt "simplify_plan" (always Never) (Do Confirm))

        it "a loop whose body never exits" $
            rejected
                "Couldn't match type: Nothing with: Just State.Category.Ty.Diff"
                (Loop "review" (Do Refactor) :: Flow _ 'State.Category.Ty.Diff 'Nothing 'State.Category.Ty.Diff)

        it "a loop whose body ends at another type than its in" $
            rejected
                "Couldn't match type: State.Category.Ty.Findings with: State.Category.Ty.Plan"
                (Loop "review" (Do Implement :> Do Review) :: Flow _ 'State.Category.Ty.Plan 'Nothing 'State.Category.Ty.Diff)

        it "capping a step with no meter" $
            rejectedShown
                "Could not deduce ‘State.Category.Meter.Meter State.Step.Build.Implement’"
                (graph (Capped (always (UpTo 1)) Stop (Step Implement)))

        {- The exit is pinned: left free, nothing asks GHC to reduce the
        clashing 'Join'. 'Ty' is imported qualified, so GHC still prints every
        type in full.
        -}
        it "a series whose two sides exit with different types" $
            rejected
                "Both sides of :> exit, with different types: State.Category.Ty.PR and State.Category.Ty.Plan"
                (Do (Merge engineers) :> Do PlanS :> Do Confirm :: Flow _ ('State.Category.Ty.List 'State.Category.Ty.PR) ('Just 'State.Category.Ty.PR) 'State.Category.Ty.Ctx)

        it "capping a flow that is neither a step nor a fork of one" $
            rejected
                "Couldn't match expected type: CapTarget"
                (Capped (always (UpTo 1)) Stop (Do Fix) :: Flow _ 'State.Category.Ty.Findings 'Nothing 'State.Category.Ty.Diff)

        it "a case after a step whose out is not a sum" $
            rejected
                "Couldn't match type: State.Category.Ty.Diff with: State.Category.Ty.Sum"
                (Do Fix :> Case (#small :-> Do Describe :& #big :-> Do Implement :> Do Describe :& End))

        it "a case branch under another summand's label" $
            rejected
                "Couldn't match type ‘\"small\"’ with ‘\"big\"’"
                (Do Triage :> Case (#big :-> Do Describe :& #small :-> Do Implement :> Do Describe :& End))

        it "a case missing a summand's branch" $
            rejected
                "Couldn't match type: '[ '(\"big\", State.Category.Ty.Plan)] with: '[]"
                (Do Triage :> Case (#small :-> Do Describe :& End))

        it "a whole flow with an uncaught exit" $
            rejectedShown
                "Couldn't match type: Just State.Category.Ty.Ctx with: Nothing"
                (flowOut (SomeFlow (Exit :> Do PlanS)))

        {- A class constraint, unlike an equality, is evidence the term only
        carries: 'graph' forces it where it draws the skip.
        -}
        it "an optional block over a sum: its skip would be one edge for two summands" $
            rejectedShown
                "A sum State.Category.Ty.Sum"
                (graph (Do Triage :> opt "refactor" (always Never) Id :> Case (#small :-> Do Describe :& #big :-> Do Implement :> Do Describe :& End)))

    describe "ill_typed_outcomes_do_not_compile" $ do
        it "an exit of a step with none" $
            rejectedShown
                "Outcome leg Exited does not fit step signature '(State.Category.Ty.Findings, Nothing, State.Category.Ty.Diff)"
                (outcomeEvent (packed Fix (by @'Exited Fix)))

        it "an outcome into a summand the sum lacks" $
            rejectedShown
                "No summand labelled \"huge\""
                (outcomeEvent (packed Triage (by @('Took "huge") Triage)))

        it "an outcome packed as another step's" $
            rejectedShown
                "Couldn't match type ‘State.Step.Review.Fix’ with ‘State.Step.Review.Review’"
                (outcomeEvent (packed Review (FixDone (Commit (Sha "") Set.empty))))

{- | The deferred error fires when the term is built, which 'show' forces.
The trivial constraint keeps GHC from binding the error outside the term,
where it would fire as the spec is built (the trick of should-not-typecheck).
The fragment is part of GHC's headline, so an unrelated error does not pass;
the lines after it quote the call, fragment included, so they are left out.
-}
rejected :: String -> ((() ~ ()) => Flow s i e o) -> Expectation
rejected = rejectedShown

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

{- | Its words one space apart: GHC wraps a long type over lines. A session
that loads the library beside its package (the quick test's) has GHC qualify
a name by its package; the fragments name it as @cabal test@ prints it.
-}
headline :: String -> String
headline = unwords . map unpackaged . concatMap words . takeWhile (not . ("In the " `isInfixOf`)) . lines

-- | A word without the @state-0.1.0.0:@ before its name, its opening quote kept.
unpackaged :: String -> String
unpackaged word = case break (== ':') rest of
    (package, ':' : name) | isPackageId package -> opening <> name
    _ -> word
  where
    (opening, rest) = span (`elem` ("\x2018(" :: String)) word
    isPackageId package = '-' `elem` package && all (\c -> isAlphaNum c || c `elem` ("-." :: String)) package && any isDigit (take 1 (reverse package))
