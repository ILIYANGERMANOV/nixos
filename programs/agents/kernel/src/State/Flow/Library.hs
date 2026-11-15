{- | #351's flow library: the small typed flows the named flows compose. Each
is a flow the skills share today, and carries its own budgets as 'PerFuel'
values, so a flow names these flows rather than their steps.
-}
module State.Flow.Library (
    agree,
    gather,
    propose,
    build,
    review,
    fixReReview,
    reviewed,
    describe,
    ship,
    gatherLoop,
    fixLoop,
) where

import State.Category.Flow (Flow (..), Name, OnEmpty (..))
import State.Category.Fuel (PerFuel (..), SkipWhen (..), always)
import State.Category.Ty (Ty (..))
import State.Step.Build (Sing (..))
import State.Step.Gather (Sing (..))
import State.Step.Plan (Sing (..))
import State.Step.Review (Sing (..))
import State.Step.Ship (Sing (..))

{- | Gather and propose until a plan is confirmed: both flows open with it.
Out of rounds is a stop, as an adjusted plan that never settles needs the user.
-}
agree :: Flow 'Ctx 'Nothing 'Plan
agree = Loop "plan" (always 4) StopOut (gather :> propose)

{- | Research, then interview, until the interview has enough. Its rounds are
the research rounds after the first, as #377 set them, plus the first.
Low may skip research on a trivial task.
-}
gather :: Flow 'Ctx 'Nothing 'Ctx
gather = Loop gatherLoop ((+ 1) <$> PerFuel 3 8 12) StopOut (Opt "research" skippableAtLow (Do Research) :> Do Interview)

-- | The gather loop's name: its questions and its @extend@ belong to it.
gatherLoop :: Name
gatherLoop = "gather"

-- | A confirmed plan exits; an adjusted one goes back to gathering. Confirm is asked at every level.
propose :: Flow 'Ctx ('Just 'Plan) 'Ctx
propose =
    Do PlanS
        :> Opt "simplify_plan" skippableAtLow (Do SimplifyP)
        :> Do Confirm

{- | @draft@ opens the draft PR before the first commit. Balanced skips the
refactor at or below 100 changed lines, Low on a trivial task.
-}
build :: Flow 'Plan 'Nothing 'Diff
build = Do Draft :> Do Implement :> Opt "refactor" (PerFuel Skippable (AtOrBelow 100) Never) (Do Refactor)

{- | The reviewed flow, one 'Diff' in and one out, so another flow can glue it
in: whoever does supplies the requirements the diff must meet. A clean
review or re-review, or a final pick, takes the exit: 'Catch' joins it with
the fixed diff.
-}
reviewed :: Flow 'Diff 'Nothing 'Diff
reviewed = Catch (review :> fixReReview)

-- | A clean review exits early; one with rows hands on its findings.
review :: Flow 'Diff ('Just 'Diff) 'Findings
review = Do Review

{- | Pick, fix and re-review the fix until a pick is final or a re-review
clean. Its rounds are the re-reviews #351 set, @n(m)@, plus the last
round's pick: pick offers only @pick.final@ once no round is left, which is
how out of rounds takes the exit, as #351 decided. 'ExitOut' cannot type
here, as the exit is no longer the loop's in type, and the fold reads no
'OnEmpty', so the loop says 'StopOut'.
-}
fixReReview :: Flow 'Findings 'Nothing 'Diff
fixReReview = Loop fixLoop (PerFuel 2 4 6) StopOut (Do Pick :> Do Fix :> Do ReReview)

-- | The fix loop's name: pick reads its rounds.
fixLoop :: Name
fixLoop = "fix"

-- | @describe@ is the final fixer, so @simplify_pr@ is never skipped: the Keep law.
describe :: Flow 'Diff 'Nothing 'PR
describe = Do Describe :> Opt "simplify_pr" (always Never) (Do SimplifyPR)

-- | No level skips @ready@: a round on an existing PR skips it by its task's shape.
ship :: Flow 'PR 'Nothing 'PR
ship = Loop "ci" (always 6) StopOut (Do AwaitCi :> Do FixPR) :> Opt "ready" (always Never) (Do Ready)

-- | Low may skip the step of a trivial task; Balanced and Max run it.
skippableAtLow :: PerFuel SkipWhen
skippableAtLow = PerFuel Skippable Never Never
