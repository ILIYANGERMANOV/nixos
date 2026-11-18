{- | #351's flow library: the small typed flows the named flows compose. Each
is a flow the skills share today, and carries its own budgets as 'PerFuel'
values, so a flow names these flows rather than their steps.
-}
module State.Flow.Library (
    choice,
    ChoiceS,
    choiceLoop,
    ChoiceLoopS,
    handled,
    Handled,
    opt,
    OptS,
    gathering,
    exploring,
    discussing,
    researchers,
    par,
    ParS,
    agree,
    AgreeS,
    gather,
    GatherS,
    research,
    ResearchS,
    discuss,
    DiscussS,
    propose,
    ProposeS,
    build,
    BuildS,
    review,
    fixReReview,
    reviewed,
    ReviewedS,
    describe,
    DescribeS,
    ship,
    ShipS,
    simplifyPlan,
    blocks,
    Blocks,
    BlocksS,
    branch,
    BranchS,
) where

import Data.Proxy (Proxy (..))
import Data.Text qualified as Text
import Data.Typeable (Typeable)
import GHC.TypeLits (KnownSymbol, Symbol, symbolVal)
import State.Category.Effect (Eff (..), Handler (..))
import State.Category.Flow (AgentRole (..), Branch (..), Branches (..), CapTarget (..), Flow (..), Group (..), Label (..), Name (..), Shape (..))
import State.Category.Fuel (PerFuel (..), SkipWhen (..), always)
import State.Category.Meter (AtCap (..), Limit (..))
import State.Category.Ty (KnownTy, NotSum, Summands, Ty, TyOf (..))
import State.Step.Build (BuildStep (..), Sing (..))
import State.Step.Fuel (FuelStep (Skip), Sing (Skip))
import State.Step.Gather (GatherStep (..), Sing (..))
import State.Step.Pick (Over, PickLabels, PickStep (Pick), Sing (Pick))
import State.Step.Plan (PlanStep (..), Sing (..))
import State.Step.Request (RequestStep (..), Sing (..))
import State.Step.Review (ReviewStep (..), Sing (..))
import State.Step.Ship (ShipStep (..), Sing (..))

{- | The agent picks one branch, by its label, and the branch runs: a
'Pick' then a 'Case'. Two steps, two events: @<name>.<label>@, then the
branch's own.
-}
choice :: (KnownTy a, NotSum a, Summands ss, Over a ss, PickLabels ss ss, Typeable a, Typeable ss) => Name -> Branches bs ss e c -> Flow (ChoiceS a ss bs) a e c
choice name branches = Do (Pick name) :> Case branches

type ChoiceS :: Ty -> [(Symbol, Ty)] -> [Shape] -> Shape
type ChoiceS a ss bs = DoS (Pick a ss) :>> CaseS bs

{- | A named flow's handler: the agent picks, in its run. Its questions stay
open, so a flow nested in another (a forked engineer, a chief's branch)
raises them to the enclosing flow: they bubble up to the root, which
'State.Role.rooted' handles once.
-}
handled :: Flow f i e o -> Flow (Handled f) i e o
handled = Handle AgentPicks

type Handled :: Shape -> Shape
type Handled f = HandleS PickE f

{- | The agent's choice, round after round, of one of the actions, or
@enough@, which runs its own flow and leaves: Elgot's iteration of a
'choice'. Each action goes back to the pick; a capped step in the actions
bounds the rounds ('State.Category.Graph.graph' refuses a loop with none).
Law, the Kleene star of a sum: the order of the actions does not matter.
-}
choiceLoop ::
    (KnownTy a, NotSum a, NotSum b, Summands ('("enough", a) ': ss), Over a ss, PickLabels ('("enough", a) ': ss) ('("enough", a) ': ss), Typeable a, Typeable ss) =>
    Name ->
    Flow f a 'Nothing b ->
    Branches bs ss 'Nothing a ->
    Flow (ChoiceLoopS a ss f bs) a 'Nothing b
choiceLoop name enough actions = Loop name (choice name (#enough :-> enough :> Exit :& actions))

type ChoiceLoopS :: Ty -> [(Symbol, Ty)] -> Shape -> [Shape] -> Shape
type ChoiceLoopS a ss enough bs = LoopS (ChoiceS a ('("enough", a) ': ss) ((enough :>> ExitS) ': bs))

{- | A block the run's Fuel may skip: a 'Skip' step picks @skip@, past the
block, or @run@. The kernel decides the pick where the level may skip.
Law: at a level that never skips, the block alone.
-}
opt :: (KnownTy a, NotSum a, Typeable a) => Name -> PerFuel SkipWhen -> Flow f a 'Nothing a -> Flow (OptS a f) a 'Nothing a
opt name skips block = Do (Skip name skips) :> Case (#skip :-> Id :& #run :-> block :& End)

type OptS :: Ty -> Shape -> Shape
type OptS a f = DoS (Skip a) :>> CaseS '[IdS, f]

{- | The flow once per item, each as a child run of the group, all at
once, then their results in the items' order: #351's @traverse@. Its
laws, @par g Id@ handing the items back and @par@ of a series a series of
@par@s, are a run's: the parent's graph draws no state of the child.
-}
par :: (KnownTy a, KnownTy b, NotSum a, NotSum b) => Group b -> Flow f a 'Nothing b -> Flow (ParS f) ('List a) 'Nothing ('List b)
par group child = Each (Fork group child) :> Await group

type ParS :: Shape -> Shape
type ParS f = EachS (ForkS f) :>> AwaitS

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
    choiceLoop
        gathering
        (merged gathering)
        (#research :-> researchersOf gathering :& #interview :-> Capped questions Extend (Step Interview) :& End)

type GatherS = ChoiceLoopS 'Ctx '[ '("research", 'Ctx), '("interview", 'Ctx)] MergedS '[ResearchersS, CappedS (DoS Interview)]

-- | Researchers alone, until the agent has enough: the facts before a ticket opens.
research :: Flow ResearchS 'Ctx 'Nothing 'Ctx
research = choiceLoop exploring (merged exploring) (#research :-> researchersOf exploring :& End)

type ResearchS = ChoiceLoopS 'Ctx '[ '("research", 'Ctx)] MergedS '[ResearchersS]

{- | The design discussion: spawn a researcher on a fact gap, or ask the user
design questions, each explained before it is asked; @extend@ grants both
budgets again at the user's yes.
-}
discuss :: Flow DiscussS 'Ctx 'Nothing 'Ctx
discuss =
    choiceLoop
        discussing
        (merged discussing)
        (#research :-> researchersOf discussing :& #discuss :-> Capped questions Extend (Step Discuss) :& End)

type DiscussS = ChoiceLoopS 'Ctx '[ '("research", 'Ctx), '("discuss", 'Ctx)] MergedS '[ResearchersS, CappedS (DoS Discuss)]

-- | The engineer's and the 10x's gather: research and interview, as the agent picks.
gathering :: Name
gathering = "gather"

{- | The architect's research before its ticket opens. Named apart from its
action, @research@, as a pick's state is its name.
-}
exploring :: Name
exploring = "exploring"

-- | The architect's design discussion: research and design questions, as the agent picks.
discussing :: Name
discussing = "discussing"

{- | A researcher per open fact group, one at Low: each spawn starts a child
of the group. In the choice's scope, as one flow may hold two choices that research.
-}
researchersOf :: Name -> Flow ResearchersS 'Ctx 'Nothing 'Ctx
researchersOf scope = Scope scope (Capped (PerFuel (UpTo 1) (UpTo 5) PerGroup) Extend (ForkOf researchers Research))

type ResearchersS = ScopeS (CappedS (ForkS (DoS Research)))

-- | Every researcher's hand-back, awaited, then merged into the notes: a choice's @enough@.
merged :: Name -> Flow MergedS 'Ctx 'Nothing 'Ctx
merged scope = Scope scope (Await researchers :> Do Notes)

type MergedS = ScopeS (AwaitS :>> DoS Notes)

{- | The researchers a choice spawns, each handing back its facts: the group's state is its 'Await'.
Run by @flows/steps.nix@'s runner of @research@, which "State.Table" checks.
-}
researchers :: Group 'Ctx
researchers = Group "researchers" (AgentRole "researcher")

-- | The questions the user is asked, by Fuel: an interview's or a discussion's.
questions :: PerFuel Limit
questions = UpTo <$> PerFuel 15 30 50

-- | A confirmed plan exits; an adjusted one goes back to gathering. Confirm is asked at every level.
propose :: Flow ProposeS 'Ctx ('Just 'Plan) 'Ctx
propose =
    Do PlanS
        :> opt simplifyPlan skippableAtLow (Do SimplifyP)
        :> Capped (always (UpTo 3)) Stop (Step Confirm)

type ProposeS = DoS PlanS :>> OptS 'Plan (DoS SimplifyP) :>> CappedS (DoS Confirm)

{- | @draft@ opens the draft PR before the first commit. Balanced skips the
refactor at or below 100 changed lines, Low on a trivial task.
-}
build :: Flow BuildS 'Plan 'Nothing 'Diff
build = Do Draft :> Do Implement :> opt "refactor" (PerFuel Skippable (AtOrBelow 100) Never) (Do Refactor)

type BuildS = DoS Draft :>> DoS Implement :>> OptS 'Diff (DoS Refactor)

{- | The reviewed flow, one 'Diff' in and one out, so another flow can glue it
in: whoever does supplies the requirements the diff must meet. A clean
review or re-review, or a final pick, takes the exit: 'Catch' joins it with
the fixed diff.
-}
reviewed :: Flow ReviewedS 'Diff 'Nothing 'Diff
reviewed = Catch (review :> fixReReview)

type ReviewedS = CatchS (DoS Review :>> FixReReviewS)

-- | A clean review exits early; one with rows hands on its findings.
review :: Flow (DoS Review) 'Diff ('Just 'Diff) 'Findings
review = Do Review

{- | Pick, fix and re-review the fix until a pick is final or a re-review
clean. Each @pick.loop@ spends a re-review, #351's @n(m)@: once none is
left, pick offers only @pick.final@.
-}
fixReReview :: Flow FixReReviewS 'Findings 'Nothing 'Diff
fixReReview = Loop "fix" (Capped (UpTo <$> PerFuel 1 3 5) Refuse (Step PickRows) :> Do Fix :> Do ReReview)

type FixReReviewS = LoopS (CappedS (DoS PickRows) :>> DoS Fix :>> DoS ReReview)

-- | @describe@ is the final fixer, so @simplify_pr@ is never skipped: the Keep law.
describe :: Flow DescribeS 'Diff 'Nothing 'PR
describe = Do Describe :> Do SimplifyPR

type DescribeS = DoS Describe :>> DoS SimplifyPR

{- | No level skips @ready@: a round on an existing PR leaves its PR as it
is, by its task's shape, and records the url it keeps.
-}
ship :: Flow ShipS 'PR 'Nothing 'PR
ship = Loop "ci" (Do AwaitCi :> Capped (always (UpTo 5)) Stop (Step FixPR)) :> Do Ready :> Case (#done :-> Id :& #skipped :-> Id :& End)

type ShipS = LoopS (DoS AwaitCi :>> CappedS (DoS FixPR)) :>> DoS Ready :>> CaseS '[IdS, IdS]

{- | The optional @simplify_plan@: besides its Fuel, a plan settled
without the user skips it ('State.Run.Fold.planSettled').
-}
simplifyPlan :: Name
simplifyPlan = "simplify_plan"

{- | Each block a request may run alone, as a branch of a 'choice': a block
that starts past 'Ctx' opens its input first, from the issue, branch or PR
the request names. Each sits in a scope of its branch's label, so its states
never meet a whole flow's, and ends in 'Result'.
-}
blocks :: Branches BlocksS Blocks 'Nothing 'Result
blocks =
    branch @"researching" research
        :& branch @"gathering" gather
        :& branch @"agreeing" agree
        :& branch @"proposing" (Loop "proposals" propose)
        :& branch @"building" (Do OpenPlan :> build)
        :& branch @"reviewing" (Do OpenBranch :> reviewed)
        :& branch @"describing" (Do OpenBranch :> describe)
        :& branch @"shipping" (Do OpenPr :> ship)
        :& End

-- | The blocks' flows, in 'Blocks'' order.
type BlocksS =
    '[ BranchS ResearchS
     , BranchS GatherS
     , BranchS AgreeS
     , BranchS (LoopS ProposeS)
     , BranchS (DoS OpenPlan :>> BuildS)
     , BranchS (DoS OpenBranch :>> ReviewedS)
     , BranchS (DoS OpenBranch :>> DescribeS)
     , BranchS (DoS OpenPr :>> ShipS)
     ]

-- | The blocks' labels, each taking the request's context.
type Blocks =
    '[ '("researching", 'Ctx)
     , '("gathering", 'Ctx)
     , '("agreeing", 'Ctx)
     , '("proposing", 'Ctx)
     , '("building", 'Ctx)
     , '("reviewing", 'Ctx)
     , '("describing", 'Ctx)
     , '("shipping", 'Ctx)
     ]

-- | A choice's branch: the flow in a scope of the branch's label, its out retyped as 'Result'.
branch :: forall l f o. (KnownSymbol l, KnownTy o, NotSum o) => Flow f 'Ctx 'Nothing o -> Branch (BranchS f) l 'Ctx 'Nothing 'Result
branch flow = Label :-> Scope (Name (Text.pack (symbolVal (Proxy @l)))) flow :> Into

type BranchS :: Shape -> Shape
type BranchS f = ScopeS f :>> IntoS

-- | Low may skip the step of a trivial task; Balanced and Max run it.
skippableAtLow :: PerFuel SkipWhen
skippableAtLow = PerFuel Skippable Never Never
