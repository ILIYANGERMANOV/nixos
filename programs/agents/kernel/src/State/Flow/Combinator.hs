{- | The glue the flow library's blocks and the roles' flows compose with: a
choice, a loop of choices, a Fuel skip, a fan-out, a cap and a choice's
branch.
-}
module State.Flow.Combinator (
    choice,
    ChoiceS,
    choiceLoop,
    ChoiceLoopS,
    skippable,
    skippableBlock,
    SkippableS,
    nameOf,
    upTo,
    parallel,
    ParallelS,
    branch,
    BranchS,
) where

import Data.Proxy (Proxy (..))
import Data.Text qualified as Text
import Data.Typeable (Typeable)
import GHC.TypeLits (KnownSymbol, Symbol, symbolVal)
import Numeric.Natural (Natural)
import State.Category.Flow (
    Branch (..),
    Branches (..),
    CapTarget (..),
    Flow (..),
    Group (..),
    Label (..),
    Name (..),
    Shape (..),
 )
import State.Category.Fuel (PerFuel (..), SkipWhen (..), always)
import State.Category.Meter (AtCap (..), Limit (..))
import State.Category.Step (StepSet (Sig, Sing, stepName), stateNameText)
import State.Category.Ty (KnownTy, NotSum, Summands, Ty, TyOf (..))
import State.Step.Fuel (FuelStep (Skip), Sing (Skip))
import State.Step.Pick (Over, PickLabels, PickStep (Pick), Sing (Pick))

{- | The agent picks one branch, by its label, and the branch runs: a
'Pick' then a 'Case'. Two steps, two events: @<name>.<label>@, then the
branch's own.
-}
choice ::
    ( KnownTy a
    , NotSum a
    , Summands ss
    , Over a ss
    , PickLabels ss ss
    , Typeable a
    , Typeable ss
    ) =>
    Name -> Branches bs ss e c -> Flow (ChoiceS a ss bs) a e c
choice name branches = Do (Pick name) :> Case branches

type ChoiceS :: Ty -> [(Symbol, Ty)] -> [Shape] -> Shape
type ChoiceS a ss bs = DoS (Pick a ss) :>> CaseS bs

{- | The agent's choice, round after round, of one of the actions, or
@enough@, which runs its own flow and leaves: Elgot's iteration of a
'choice'. Each action goes back to the pick; a capped step in the actions
bounds the rounds ('State.Category.Graph.graph' refuses a loop with none).
Law, the Kleene star of a sum: the order of the actions does not matter.
-}
choiceLoop ::
    ( KnownTy a
    , NotSum a
    , NotSum b
    , Summands ('("enough", a) ': ss)
    , Over a ss
    , PickLabels ('("enough", a) ': ss) ('("enough", a) ': ss)
    , Typeable a
    , Typeable ss
    ) =>
    Name ->
    Flow f a 'Nothing b ->
    Branches bs ss 'Nothing a ->
    Flow (ChoiceLoopS a ss f bs) a 'Nothing b
choiceLoop name enough actions = Loop name (choice name (#enough :-> enough :> Exit :& actions))

type ChoiceLoopS :: Ty -> [(Symbol, Ty)] -> Shape -> [Shape] -> Shape
type ChoiceLoopS a ss enough bs =
    LoopS (ChoiceS a ('("enough", a) ': ss) ((enough :>> ExitS) ': bs))

{- | A block the run's Fuel may skip: a 'Skip' step picks @skip@, past the
block, or @run@. The kernel decides the pick where the level may skip.
Law: at a level that never skips, the block alone.
-}
skippable ::
    (StepSet k, Sig s ~ '(a, 'Nothing, a), KnownTy a, NotSum a, Typeable a) =>
    Sing (s :: k) ->
    PerFuel SkipWhen ->
    Flow (SkippableS a (DoS s)) a 'Nothing a
skippable step skips = skippableBlock (nameOf step) skips (Do step)

-- | 'skippable' over any block, its skip named @name@.
skippableBlock ::
    (KnownTy a, NotSum a, Typeable a) =>
    Name ->
    PerFuel SkipWhen ->
    Flow f a 'Nothing a ->
    Flow (SkippableS a f) a 'Nothing a
skippableBlock name skips block = Do (Skip name skips) :> Case (#skip :-> Id :& #run :-> block :& End)

type SkippableS :: Ty -> Shape -> Shape
type SkippableS a f = DoS (Skip a) :>> CaseS '[IdS, f]

{- | The flow once per item, each as a child run of the group, all at
once, then their results in the items' order: #351's @traverse@. Its
laws, @parallel g Id@ handing the items back and @parallel@ of a series a
series of @parallel@s, are a run's: the parent's graph draws no state of the child.
-}
parallel ::
    (KnownTy a, KnownTy b, NotSum a, NotSum b) =>
    Group b ->
    Flow f a 'Nothing b ->
    Flow (ParallelS f) ('List a) 'Nothing ('List b)
parallel group child = Each (Fork group child) :> Await group

type ParallelS :: Shape -> Shape
type ParallelS f = EachS (ForkS f) :>> AwaitS

-- | A step capped alike at every level: @n@ spends, then the cap's way on.
upTo :: Natural -> AtCap -> CapTarget c i e o -> Flow (CappedS c) i e o
upTo n = Capped (always (UpTo n))

-- | A choice's branch: the flow in a scope of the branch's label, its out retyped as 'Result'.
branch ::
    forall l f o.
    (KnownSymbol l, KnownTy o, NotSum o) =>
    Flow f 'Ctx 'Nothing o -> Branch (BranchS f) l 'Ctx 'Nothing 'Result
branch flow = Label :-> Scope (Name (Text.pack (symbolVal (Proxy @l)))) flow :> Into

type BranchS :: Shape -> Shape
type BranchS f = ScopeS f :>> IntoS

-- | A step's wire name as a flow name: a skip named after its block's one step.
nameOf :: (StepSet k) => Sing (s :: k) -> Name
nameOf = Name . stateNameText . stepName
