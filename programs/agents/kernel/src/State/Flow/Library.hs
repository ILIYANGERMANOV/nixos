{- | #351's flow library: the small typed flows the named flows compose. Each
is a flow the skills share today, and carries its own budgets as 'PerFuel'
values, so a flow names these flows rather than their steps.
-}
module State.Flow.Library (
    choice,
    choiceLoop,
    opt,
    par,
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
    simplifyPlan,
    blocks,
    branch,
) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Typeable (Typeable)
import State.Category.Flow (Branch (..), Branches (..), Flow (..), Group, Name, nameText, spawn)
import State.Category.Flow qualified as Flow
import State.Category.Fuel (PerFuel (..), SkipWhen (..), always)
import State.Category.Meter (AtCap (..), Limit (..))
import State.Category.Step (OutcomeName (..))
import State.Category.Ty (KnownTy, NotSum, Summands, TyOf (..))
import State.Step.Build (Sing (..))
import State.Step.Choice (discussing, exploring, gathering)
import State.Step.Fuel (Sing (Skip))
import State.Step.Gather (Sing (..))
import State.Step.Pick (Over, PickLabels, Sing (Pick))
import State.Step.Plan (Sing (..))
import State.Step.Request (Sing (..))
import State.Step.Review (Sing (..))
import State.Step.Ship (Sing (..))

{- | The agent picks one branch, by its label, and the branch runs: a
'Pick' then a 'Case'. Two steps, two events: @<name>.<label>@, then the
branch's own.
-}
choice :: (KnownTy a, NotSum a, Summands ss, Over a ss, PickLabels ss ss, Typeable a, Typeable ss) => Name -> Branches ss e c -> Flow a e c
choice name branches = Do (Pick name) :> Case branches

{- | The agent's choice, round after round, of one of the actions, or
@enough@, which runs its own flow and leaves: Elgot's iteration of a
'choice'. Each action goes back to the pick; a capped step in the actions
bounds the rounds ('State.Category.Graph.graph' refuses a loop with none).
Law, the Kleene star of a sum: the order of the actions does not matter.
-}
choiceLoop ::
    (KnownTy a, NotSum a, NotSum b, Summands ('("enough", a) ': ss), Over a ss, PickLabels ('("enough", a) ': ss) ('("enough", a) ': ss), Typeable a, Typeable ss) =>
    Name ->
    Flow a 'Nothing b ->
    Branches ss 'Nothing a ->
    Flow a 'Nothing b
choiceLoop name enough actions = Loop name (choice name (#enough :-> enough :> Exit :& actions))

{- | A block the run's Fuel may skip: a 'Skip' step picks @skip@, past the
block, or @run@. The kernel decides the pick where the level may skip.
Law: at a level that never skips, the block alone.
-}
opt :: (KnownTy a, NotSum a, Typeable a) => Name -> PerFuel SkipWhen -> Flow a 'Nothing a -> Flow a 'Nothing a
opt name skips block = Do (Skip name skips) :> Case (#skip :-> Id :& #run :-> block :& End)

{- | The flow once per item, each as a child run of the group, all at
once, then their results in the items' order: #351's @traverse@. Its
laws, @par g Id@ handing the items back and @par@ of a series a series of
@par@s, are a run's: the parent's graph draws no state of the child.
-}
par :: (KnownTy a, KnownTy b, NotSum a, NotSum b) => Group b -> Flow a 'Nothing b -> Flow ('List a) 'Nothing ('List b)
par group child = Each (Fork group child) :> Await group

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
    Flow.choiceLoop
        gathering
        [ researchers
        , Capped questions Extend Interview
        ]

-- | Researchers alone, until the agent has enough: the facts before a ticket opens.
research :: Flow 'Ctx 'Nothing 'Ctx
research = Flow.choiceLoop exploring [researchers]

{- | The design discussion: spawn a researcher on a fact gap, or ask the user
a design question, each explained before it is asked; @extend@ grants both
budgets again at the user's yes.
-}
discuss :: Flow 'Ctx 'Nothing 'Ctx
discuss =
    Flow.choiceLoop
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
        :> opt simplifyPlan skippableAtLow (Do SimplifyP)
        :> Capped (always (UpTo 3)) Stop Confirm

{- | @draft@ opens the draft PR before the first commit. Balanced skips the
refactor at or below 100 changed lines, Low on a trivial task.
-}
build :: Flow 'Plan 'Nothing 'Diff
build = Do Draft :> Do Implement :> opt "refactor" (PerFuel Skippable (AtOrBelow 100) Never) (Do Refactor)

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
fixReReview = Loop "fix" (Capped (UpTo <$> PerFuel 1 3 5) Refuse PickRows :> Do Fix :> Do ReReview)

-- | @describe@ is the final fixer, so @simplify_pr@ is never skipped: the Keep law.
describe :: Flow 'Diff 'Nothing 'PR
describe = Do Describe :> Do SimplifyPR

{- | No level skips @ready@: a round on an existing PR leaves its PR as it
is, by its task's shape, and records the url it keeps.
-}
ship :: Flow 'PR 'Nothing 'PR
ship = Loop "ci" (Do AwaitCi :> Capped (always (UpTo 5)) Stop FixPR) :> Do Ready :> Case (#done :-> Id :& #skipped :-> Id :& End)

{- | The optional @simplify_plan@: besides its Fuel, a plan settled
without the user skips it ('State.Run.Fold.planSettled').
-}
simplifyPlan :: Name
simplifyPlan = "simplify_plan"

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
