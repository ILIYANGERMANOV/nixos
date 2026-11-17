{- | #351's flow library: the small typed flows the named flows compose. Each
is a flow the skills share today, and carries its own budgets as 'PerFuel'
values, so a flow names these flows rather than their steps.
-}
module State.Flow.Library (
    agree,
    gather,
    research,
    discuss,
    propose,
    build,
    review,
    fixReReview,
    reviewed,
    describe,
    ship,
    blocks,
    branch,
) where

import Data.List.NonEmpty (NonEmpty (..))
import State.Category.Flow (Flow (..), Name, choiceLoop, nameText, spawn)
import State.Category.Fuel (PerFuel (..), SkipWhen (..), always)
import State.Category.Meter (AtCap (..), Limit (..))
import State.Category.Step (OutcomeName (..))
import State.Category.Ty (KnownTy, NotSum, Ty (..))
import State.Step.Build (Sing (..))
import State.Step.Choice (discussing, exploring, gathering)
import State.Step.Gather (Sing (..))
import State.Step.Plan (Sing (..))
import State.Step.Request (Sing (..))
import State.Step.Review (Sing (..))
import State.Step.Ship (Sing (..))

{- | Gather and propose until a plan is confirmed: both flows open with it.
Three adjusted plans are the cap, then a stop: a plan that never settles
needs the user.
-}
agree :: Flow 'Ctx 'Nothing 'Plan
agree = Loop "plan" (gather :> propose)

{- | The agent's choice, until it has enough: spawn a researcher on a fact
gap, in the background, or ask the user a question. More researchers may
follow any answer; @enough@ waits for every researcher to hand back. Its
meters are the researchers and the questions; at either cap the user is
asked whether to go on, and @extend@ grants both again.
-}
gather :: Flow 'Ctx 'Nothing 'Ctx
gather =
    choiceLoop
        gathering
        [ researchers
        , Capped questions Extend Interview
        ]

-- | Researchers alone, until the agent has enough: the facts before a ticket opens.
research :: Flow 'Ctx 'Nothing 'Ctx
research = choiceLoop exploring [researchers]

{- | The design discussion: spawn a researcher on a fact gap, or ask the user
a design question, each explained before it is asked; @extend@ grants both
budgets again at the user's yes.
-}
discuss :: Flow 'Ctx 'Nothing 'Ctx
discuss =
    choiceLoop
        discussing
        [ researchers
        , Capped questions Extend Discuss
        ]

-- | A researcher per open fact group, one at Low: each spawn opens a child.
researchers :: Flow 'Ctx 'Nothing 'Ctx
researchers = spawn (PerFuel (UpTo 1) (UpTo 5) PerGroup) Extend Research

-- | The questions the user is asked, by Fuel: an interview's or a discussion's.
questions :: PerFuel Limit
questions = UpTo <$> PerFuel 15 30 50

-- | A confirmed plan exits; an adjusted one goes back to gathering. Confirm is asked at every level.
propose :: Flow 'Ctx ('Just 'Plan) 'Ctx
propose =
    Do PlanS
        :> Opt "simplify_plan" skippableAtLow (Do SimplifyP)
        :> Capped (always (UpTo 3)) Stop Confirm

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
clean. Each @pick.loop@ spends a re-review, #351's @n(m)@: once none is
left, pick offers only @pick.final@.
-}
fixReReview :: Flow 'Findings 'Nothing 'Diff
fixReReview = Loop "fix" (Capped (UpTo <$> PerFuel 1 3 5) Refuse Pick :> Do Fix :> Do ReReview)

-- | @describe@ is the final fixer, so @simplify_pr@ is never skipped: the Keep law.
describe :: Flow 'Diff 'Nothing 'PR
describe = Do Describe :> Opt "simplify_pr" (always Never) (Do SimplifyPR)

-- | No level skips @ready@: a round on an existing PR skips it by its task's shape.
ship :: Flow 'PR 'Nothing 'PR
ship = Loop "ci" (Do AwaitCi :> Capped (always (UpTo 5)) Stop FixPR) :> Opt "ready" (always Never) (Do Ready)

{- | Each block a request may run alone, as a branch of a route: a block
that starts past 'Ctx' opens its input first, from the issue, branch or PR
the request names. Each sits in a scope of its branch's name, so its states
never meet a whole flow's, and ends in 'Result'.
-}
blocks :: NonEmpty (OutcomeName, Flow 'Ctx 'Nothing 'Result)
blocks =
    branch "researching" research
        :| [ branch "gathering" gather
           , branch "agreeing" agree
           , branch "proposing" (Loop "proposals" propose)
           , branch "building" (Do OpenPlan :> build)
           , branch "reviewing" (Do OpenBranch :> reviewed)
           , branch "describing" (Do OpenBranch :> describe)
           , branch "shipping" (Do OpenPr :> ship)
           ]

-- | A route's branch: the flow in a scope of the branch's name, its out retyped as 'Result'.
branch :: (KnownTy o, NotSum o) => Name -> Flow 'Ctx 'Nothing o -> (OutcomeName, Flow 'Ctx 'Nothing 'Result)
branch name flow = (OutcomeName (nameText name), Scope name flow :> Into)

-- | Low may skip the step of a trivial task; Balanced and Max run it.
skippableAtLow :: PerFuel SkipWhen
skippableAtLow = PerFuel Skippable Never Never
