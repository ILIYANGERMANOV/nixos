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
import State.Category.Effect (Handler (..))
import State.Category.Flow (
    Branch (..),
    Branches (..),
    CapTarget (..),
    Flow (..),
    Shape (..),
 )
import State.Category.Fuel (SkipWhen (..), always)
import State.Category.Graph (graph)
import State.Category.Meter (AtCap (..))
import State.Category.Step (Leg (..), Outcome, Sing, outcomeEvent, packed)
import State.Category.Ty qualified
import State.Flow.Attend (Sing (..))
import State.Flow.Block (gather)
import State.Flow.Combinator (skippable, skippableBlock, upTo)
import State.Flow.Role.Architect (architect)
import State.Flow.Role.Chief (chief)
import State.Flow.Role.Engineer (engineer)
import State.Flow.Role.TenX (tenX)
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
                (skippable Implement (always Never))

        it "an optional step with an exit" $
            rejected
                "Couldn't match type: Just State.Category.Ty.Plan with: Nothing"
                (skippable Confirm (always Never))

        it "a loop whose body never exits" $
            rejected
                "Couldn't match type: Nothing with: Just State.Category.Ty.Diff"
                ( Loop "review" (Do Refactor) ::
                    Flow _ 'State.Category.Ty.Diff 'Nothing 'State.Category.Ty.Diff
                )

        it "a loop whose body ends at another type than its in" $
            rejected
                "Couldn't match type: State.Category.Ty.Findings with: State.Category.Ty.Plan"
                ( Loop "review" (Do Implement :> Do Review) ::
                    Flow _ 'State.Category.Ty.Plan 'Nothing 'State.Category.Ty.Diff
                )

        it "capping a step with no meter" $
            rejectedShown
                "Could not deduce ‘State.Category.Meter.Meter State.Step.Build.Implement’"
                (graph (upTo 1 Stop (Step Implement)))

        {- The exit is pinned: left free, nothing asks GHC to reduce the
        clashing 'Join'. 'Ty' is imported qualified, so GHC still prints every
        type in full.
        -}
        it "a series whose two sides exit with different types" $
            rejected
                "Both sides of :> exit, with different types: State.Category.Ty.PR and State.Category.Ty.Plan"
                ( Do (Merge engineers) :> Do PlanS :> Do Confirm ::
                    Flow
                        _
                        ('State.Category.Ty.List 'State.Category.Ty.PR)
                        ('Just 'State.Category.Ty.PR)
                        'State.Category.Ty.Ctx
                )

        it "capping a flow that is neither a step nor a fork of one" $
            rejected
                "Couldn't match expected type: CapTarget"
                ( upTo 1 Stop (Do Fix) ::
                    Flow _ 'State.Category.Ty.Findings 'Nothing 'State.Category.Ty.Diff
                )

        it "a case after a step whose out is not a sum" $
            rejected
                "Couldn't match type: State.Category.Ty.Diff with: State.Category.Ty.Sum"
                ( Do Fix
                    :> Case (#small :-> Do Describe :& #big :-> Do Implement :> Do Describe :& End)
                )

        it "a case branch under another summand's label" $
            rejected
                "Couldn't match type ‘\"small\"’ with ‘\"big\"’"
                ( Do Triage
                    :> Case (#big :-> Do Describe :& #small :-> Do Implement :> Do Describe :& End)
                )

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
                ( graph
                    ( Do Triage
                        :> skippableBlock "refactor" (always Never) Id
                        :> Case (#small :-> Do Describe :& #big :-> Do Implement :> Do Describe :& End)
                    )
                )

    {- 'Unhandled' names the effects left, in 'Eff''s order. 'Eff' is not
    imported, so GHC prints its constructors qualified.
    -}
    describe "a_whole_flow_with_an_unhandled_effect_does_not_compile" $ do
        it "a pick no handler takes" $
            rejectedShown
                "A whole flow leaves effects unhandled: '[State.Category.Effect.PickE]"
                (flowOut (SomeFlow (Handle AskHandler gather)))

        it "a question no handler takes" $
            rejectedShown
                "A whole flow leaves effects unhandled: '[State.Category.Effect.AskE]"
                (flowOut (SomeFlow (Handle PickHandler gather)))

        it "a wait for focus no handler takes" $
            rejectedShown
                "A whole flow leaves effects unhandled: '[State.Category.Effect.FocusE]"
                (flowOut (SomeFlow (Handle AskHandler (Handle PickHandler (Do Attend)))))

        it "each registered flow, its pick handler removed" $ do
            let fragment = "A whole flow leaves effects unhandled: '[State.Category.Effect.PickE]"
            rejectedShown
                fragment
                ( flowOut
                    (SomeFlow (Handle AskHandler (Handle AwaitHandler (unhandled engineer))))
                )
            rejectedShown
                fragment
                (flowOut (SomeFlow (Handle AskHandler (Handle AwaitHandler (unhandled tenX)))))
            rejectedShown
                fragment
                (flowOut (SomeFlow (Handle AskHandler (unhandled architect))))
            rejectedShown
                fragment
                (flowOut (SomeFlow (Handle AskHandler (Handle AwaitHandler (unhandled chief)))))

        it
            "each registered flow, its principal's handler removed: its questions bubble out"
            $ do
                let fragment = "A whole flow leaves effects unhandled: '[State.Category.Effect.AskE]"
                rejectedShown fragment (flowOut (SomeFlow (Handle AwaitHandler engineer)))
                rejectedShown fragment (flowOut (SomeFlow (Handle AwaitHandler tenX)))
                rejectedShown fragment (flowOut (SomeFlow architect))
                rejectedShown fragment (flowOut (SomeFlow (Handle AwaitHandler chief)))

        it "each flow that ships a PR, its wait handler removed: its waits bubble out" $ do
            let fragment = "A whole flow leaves effects unhandled: '[State.Category.Effect.AwaitE]"
            rejectedShown fragment (flowOut (SomeFlow (Handle AskHandler engineer)))
            rejectedShown fragment (flowOut (SomeFlow (Handle AskHandler tenX)))
            rejectedShown fragment (flowOut (SomeFlow (Handle AskHandler chief)))

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

-- | The flow under its outermost handler: a registered flow's is the agent's picks.
unhandled :: Flow (HandleS eff s) i e o -> Flow s i e o
unhandled (Handle _ flow) = flow

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
a name by its unit id; the fragments name it as @cabal test@ prints it.
-}
headline :: String -> String
headline =
    unpackaged
        . unwords
        . concatMap words
        . takeWhile (not . ("In the " `isInfixOf`))
        . lines

{- | The text without unit ids before names (@state-0.1.0.0-inplace:@, or a
hash in place of @inplace@), whatever punctuation precedes them. A unit id is
a run of letters, digits, dots and hyphens holding a version (a hyphen then a
digit), directly followed by a colon.
-}
unpackaged :: String -> String
unpackaged text = case span isUnitChar text of
    ("", c : rest) -> c : unpackaged rest
    ("", "") -> ""
    (unit, ':' : rest) | isVersioned unit -> unpackaged rest
    (run, rest) -> run <> unpackaged rest
  where
    isUnitChar c = isAlphaNum c || c `elem` ("-." :: String)
    isVersioned unit = any (\(a, b) -> a == '-' && isDigit b) (zip unit (drop 1 unit))
