{- | #351's flow library: the small typed flows the named flows compose. Each
is a flow the skills share today, and carries its own budgets as 'PerFuel'
values, so a flow names these flows rather than their steps.
-}
module State.Flow.Block (
    agree,
    AgreeS,
    gather,
    GatherS,
    gatherResearcherLimit,
    research,
    ResearchS,
    researchLoop,
    ResearchLoopS,
    discuss,
    DiscussS,
    propose,
    ProposeS,
    build,
    BuildS,
    fixReReview,
    review,
    ReviewS,
    describe,
    DescribeS,
    ship,
    ShipS,
) where

import Data.Typeable (Typeable)
import GHC.TypeLits (Symbol)
import State.Category.Flow (
    AgentRole (..),
    Branch (..),
    Branches (..),
    CapTarget (..),
    Flow (..),
    Group (..),
    Name (..),
    Shape (..),
 )
import State.Category.Fuel (PerFuel (..), SkipWhen (..))
import State.Category.Meter (AtCap (..), Limit (..))
import State.Category.Ty (Summands, Ty, TyOf (..))
import State.Flow.Combinator (
    ChoiceLoopS,
    SkippableS,
    choiceLoop,
    skippable,
    skippableBlock,
    upTo,
 )
import State.Step.Build (BuildStep (..), Sing (..))
import State.Step.Gather (GatherStep (..), Sing (..))
import State.Step.Pick (Over, PickLabels)
import State.Step.Plan (PlanStep (..), Sing (..), refineName)
import State.Step.Review (ReviewStep (..), Sing (..))
import State.Step.Ship (ShipStep (..), Sing (..))

{- | Gather and propose until a plan is confirmed: both flows open with it.
Three adjusted plans are the cap, then a stop: a plan that never settles
needs the user.
-}
agree :: Flow AgreeS 'Ctx 'Nothing 'Plan
agree = Loop "plan" (gather :> propose)

type AgreeS = LoopS (GatherS :>> ProposeS)

{- | The agent's choice, until it has enough: spawn a researcher on a fact
gap, in the background, or interview the user. More researchers may follow
any answer; @enough@ waits for every researcher to hand back, then merges
their notes. Its meters are the researchers and the questions; at either cap
the user is asked whether to go on, and @extend@ grants both again.
-}
gather :: Flow GatherS 'Ctx 'Nothing 'Ctx
gather =
    researchLoop
        "gather"
        gatherResearcherLimit
        (#interview :-> Capped questionLimit Extend (Step Interview) :& End)
  where
    -- The questions the user is asked in an interview, by Fuel.
    questionLimit = UpTo <$> PerFuel 15 30 50

type GatherS = ResearchLoopS '[ '("interview", 'Ctx)] '[CappedS (DoS Interview)]

{- | Researchers alone, up to the given cap, until the agent has enough: the
facts before a ticket opens. Named apart from its action, @research@, as a
pick's state is its name.
-}
research :: PerFuel Limit -> Flow ResearchS 'Ctx 'Nothing 'Ctx
research cap = researchLoop "exploring" cap End

type ResearchS = ResearchLoopS '[] '[]

{- | The design discussion named @name@: spawn a researcher on a fact gap, or
ask the user design questions, each explained before it is asked, then the
other actions; @extend@ grants both budgets again at the user's yes.
-}
discuss ::
    ( Summands ('("enough", 'Ctx) ': '("research", 'Ctx) ': '("discuss", 'Ctx) ': ss)
    , Over 'Ctx ss
    , PickLabels
        ('("enough", 'Ctx) ': '("research", 'Ctx) ': '("discuss", 'Ctx) ': ss)
        ('("enough", 'Ctx) ': '("research", 'Ctx) ': '("discuss", 'Ctx) ': ss)
    , Typeable ss
    ) =>
    Name ->
    Branches bs ss 'Nothing 'Ctx ->
    Flow (DiscussS ss bs) 'Ctx 'Nothing 'Ctx
discuss name actions =
    researchLoop
        name
        designResearcherLimit
        (#discuss :-> Capped designQuestionLimit Extend (Step Discuss) :& actions)
  where
    -- The researchers a design spawns, by Fuel: the architect's and the chief's discussion.
    designResearcherLimit = UpTo <$> PerFuel 10 30 60
    -- The design questions the user is asked in a discussion, by Fuel.
    designQuestionLimit = UpTo <$> PerFuel 50 100 200

type DiscussS :: [(Symbol, Ty)] -> [Shape] -> Shape
type DiscussS ss bs =
    ResearchLoopS ('("discuss", 'Ctx) ': ss) (CappedS (DoS Discuss) ': bs)

{- | A 'choiceLoop' named @name@ whose first action, @research@, spawns
researchers up to the cap and whose @enough@ merges their notes, both in its
scope, then the other actions. The name is the pick's state and the
researchers' scope.
-}
researchLoop ::
    ( Summands ('("enough", 'Ctx) ': '("research", 'Ctx) ': ss)
    , Over 'Ctx ss
    , PickLabels
        ('("enough", 'Ctx) ': '("research", 'Ctx) ': ss)
        ('("enough", 'Ctx) ': '("research", 'Ctx) ': ss)
    , Typeable ss
    ) =>
    Name ->
    PerFuel Limit ->
    Branches bs ss 'Nothing 'Ctx ->
    Flow (ResearchLoopS ss bs) 'Ctx 'Nothing 'Ctx
researchLoop name cap actions = choiceLoop name merged (#research :-> researchersOf :& actions)
  where
    -- Researchers up to the cap: each spawn starts a child of the group. In
    -- the choice's scope, as one flow may hold two choices that research.
    researchersOf = Scope name (Capped cap Extend (ForkOf researchers Research))
    -- Every researcher's hand-back, awaited, then merged into the notes: a choice's @enough@.
    merged = Scope name (Await researchers :> Do Notes)
    -- The researchers a choice spawns, each handing back its facts: the group's state is its 'Await'.
    -- Run by @flows/steps.nix@'s runner of @research@, which "State.Table" checks.
    researchers = Group "researchers" (AgentRole "researcher")

type ResearchLoopS :: [(Symbol, Ty)] -> [Shape] -> Shape
type ResearchLoopS ss bs =
    ChoiceLoopS 'Ctx ('("research", 'Ctx) ': ss) MergedS (ResearchersS ': bs)

type ResearchersS = ScopeS (CappedS (ForkS (DoS Research)))

type MergedS = ScopeS (AwaitS :>> DoS Notes)

-- | The researchers a gathering spawns, by Fuel: one at Low, one per open fact group at Max.
gatherResearcherLimit :: PerFuel Limit
gatherResearcherLimit = PerFuel (UpTo 1) (UpTo 5) PerGroup

{- | A confirmed plan exits; an adjusted one goes back to gathering. Confirm
is asked at every level, after the plan is presented to the user.
-}
propose :: Flow ProposeS 'Ctx ('Just 'Plan) 'Ctx
propose = Do PlanS :> refine :> Do Present :> upTo 3 Stop (Step Confirm)

type ProposeS =
    DoS PlanS :>> SkippableS 'Plan RefineS :>> DoS Present :>> CappedS (DoS Confirm)

{- | The passes that refine a plan, in order: add or drop one here. Each
hands back findings; the lead alone edits the plan. Low may skip the block
on a trivial task; Balanced and Max run it. Besides its Fuel, a plan
settled without the user skips it ('refineName').
-}
refine :: Flow (SkippableS 'Plan RefineS) 'Plan 'Nothing 'Plan
refine =
    skippableBlock refineName (PerFuel Skippable Never Never) $
        Do SimplifyP :> Do StandardsP :> Do AlignP

type RefineS = DoS SimplifyP :>> DoS StandardsP :>> DoS AlignP

{- | @draft@ opens the draft PR before the first commit. Balanced skips the
refactor at or below 100 changed lines, Low on a trivial task.
-}
build :: Flow BuildS 'Plan 'Nothing 'Diff
build =
    Do Draft
        :> Do Implement
        :> skippable Refactor (PerFuel Skippable (AtOrBelow 100) Never)

type BuildS = DoS Draft :>> DoS Implement :>> SkippableS 'Diff (DoS Refactor)

{- | The review flow, one 'Diff' in and one out, so another flow can glue it
in: whoever does supplies the requirements the diff must meet. A clean
review exits early; one with rows hands on its findings. A clean review or
re-review, or a final pick, takes the exit: 'Catch' joins it with the fixed
diff.
-}
review :: Flow ReviewS 'Diff 'Nothing 'Diff
review = Catch (Do Review :> fixReReview)

type ReviewS = CatchS (DoS Review :>> FixReReviewS)

{- | Pick, fix and re-review the fix until a pick is final or a re-review
clean. Each @pick.loop@ spends a re-review, #351's @n(m)@: once none is
left, pick offers only @pick.final@.
-}
fixReReview :: Flow FixReReviewS 'Findings 'Nothing 'Diff
fixReReview =
    Loop
        "fix"
        (Capped (UpTo <$> PerFuel 1 3 5) Refuse (Step PickRows) :> Do Fix :> Do ReReview)

type FixReReviewS = LoopS (CappedS (DoS PickRows) :>> DoS Fix :>> DoS ReReview)

-- | @describe@ is the final fixer, so @simplify_pr@ is never skipped: the Keep law.
describe :: Flow DescribeS 'Diff 'Nothing 'PR
describe = Do Describe :> Do SimplifyPR

type DescribeS = DoS Describe :>> DoS SimplifyPR

{- | No level skips @ready@: a round on an existing PR leaves its PR as it
is, by its task's shape, and records the url it keeps.
-}
ship :: Flow ShipS 'PR 'Nothing 'PR
ship =
    Loop "ci" (Do AwaitCi :> upTo 5 Stop (Step FixPR))
        :> Do Ready
        :> Case (#done :-> Id :& #skipped :-> Id :& End)

type ShipS =
    LoopS (DoS AwaitCi :>> CappedS (DoS FixPR)) :>> DoS Ready :>> CaseS '[IdS, IdS]
