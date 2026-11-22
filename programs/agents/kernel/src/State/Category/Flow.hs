{-# LANGUAGE TypeData #-}
{-# LANGUAGE UndecidableInstances #-}

{- | #351's category @Flow@: typed terms over the steps of "State.Category.Step"'s layers. The
indexes make an ill-typed gluing a compile error (law Typed gluing), and
'Loop' exists only on the shapes #351 allows. Every
budget is a 'Capped' step's meter (decision 13). A flow
is built by composing small flows ("State.Flow.Block"), each reusable in
any flow.
-}
module State.Category.Flow (
    Flow (..),
    Shape (..),
    Effects,
    CapTarget (..),
    Branches (..),
    Branch (..),
    branchesWith,
    Label (..),
    Group (..),
    AgentRole (..),
    roleText,
    Join,
    Name (..),
    nameText,
    scoped,
    ScopePath,
    scopePath,
    scopeNames,
    qualify,
    qualifyEvent,
    qualifyText,
    unqualify,
    namedState,
    enoughOutcome,
    FanEvent (..),
    fanEvent,
) where

import Data.String (IsString)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.OverloadedLabels (IsLabel (..))
import GHC.TypeError (ErrorMessage (..), TypeError)
import GHC.TypeLits (KnownSymbol, Symbol)
import State.Category.Effect (
    Eff (..),
    Effs,
    FromOps,
    Handler,
    None,
    ToList,
    Union,
    Without,
 )
import State.Category.Fuel (PerFuel)
import State.Category.Meter (AtCap, Limit, Meter)
import State.Category.Step (
    EventName (..),
    OutcomeName (..),
    StateName (..),
    StepSet (..),
    handedBackOutcome,
    spawnedOutcome,
 )
import State.Category.Ty (KnownTy, NotSum, Ty, TyOf (..))

{- | The exit of @f ':>' g@: either side's, and the same type when both have
one. The last equation turns a mismatch into a message naming both types,
where a stuck family would leave GHC printing @Join@ itself.
-}
type Join :: Maybe Ty -> Maybe Ty -> Maybe Ty
type family Join a b where
    Join 'Nothing b = b
    Join a 'Nothing = a
    Join ('Just a) ('Just a) = 'Just a
    Join ('Just a) ('Just b) =
        TypeError
            ( 'Text "Both sides of :> exit, with different types: "
                ':<>: 'ShowType a
                ':<>: 'Text " and "
                ':<>: 'ShowType b
            )

{- | A flow's structure, one constructor per 'Flow' constructor: each
builds its own, so a term's type holds its whole structure, and
'Effects' reads the effects off it. Names and limits are values, not
structure, so they are not here; a case's labels are its input sum's.
-}
type data Shape where
    DoS :: k -> Shape
    IdS :: Shape
    IntoS :: Shape
    (:>>) :: Shape -> Shape -> Shape
    CappedS :: Shape -> Shape
    LoopS :: Shape -> Shape
    CaseS :: [Shape] -> Shape
    ExitS :: Shape
    EachS :: Shape -> Shape
    ForkS :: Shape -> Shape
    AwaitS :: Shape
    CatchS :: Shape -> Shape
    ScopeS :: Shape -> Shape
    HandleS :: Eff -> Shape -> Shape

infixr 5 :>>

{- | The effects a flow raises and does not handle, in 'Eff''s order: its
steps' ('Raises'), a forked child's included, less each one a 'Handle'
around them takes.
-}
type Effects :: Shape -> [Eff]
type Effects s = ToList (EffectSet s)

{- | 'Effects' as a set: one equation per constructor, each child's set
reduced once ("State.Category.Effect"'s 'Effs' says why).
-}
type EffectSet :: Shape -> Effs
type family EffectSet s where
    EffectSet (DoS s) = FromOps (Raises s)
    EffectSet IdS = None
    EffectSet IntoS = None
    EffectSet (f :>> g) = Union (EffectSet f) (EffectSet g)
    EffectSet (CappedS c) = EffectSet c
    EffectSet (LoopS f) = EffectSet f
    EffectSet (CaseS bs) = BranchEffects bs
    EffectSet ExitS = None
    EffectSet (EachS f) = EffectSet f
    EffectSet (ForkS f) = EffectSet f
    EffectSet AwaitS = None
    EffectSet (CatchS f) = EffectSet f
    EffectSet (ScopeS f) = EffectSet f
    EffectSet (HandleS eff f) = Without eff (EffectSet f)

type BranchEffects :: [Shape] -> Effs
type family BranchEffects bs where
    BranchEffects '[] = None
    BranchEffects (b ': bs) = Union (EffectSet b) (BranchEffects bs)

{- | @s@: the structure ('Shape'). @i@: in. @e@: the exit, if any. @o@:
continue. Each constructor's
comment states its law, read off the graph a run walks ("State.Category.Graph").
A loop, skip or group is known by its 'Name'; a budget is a 'Capped'
step, carrying its limits as 'PerFuel' data: no global table of ids.
-}
data Flow (s :: Shape) (i :: Ty) (e :: Maybe Ty) (o :: Ty) where
    {- | One step, of any layer: its signature is the term's type. A step takes
    one type, never a sum. Law: one state, one edge per outcome.
    -}
    Do ::
        (StepSet k, Sig s ~ '(i, e, o), KnownTy i, KnownTy o, NotSum i) =>
        Sing (s :: k) -> Flow (DoS s) i e o
    -- | Identity: no step runs. Law: @Id :> f = f = f :> Id@.
    Id :: Flow IdS a 'Nothing a
    {- | Retype as 'Result': no step runs, nothing is recorded, as 'Id'. The
    chief's route joins its branches' outs here. Law: @f :> Into@ walks as @f@.
    -}
    Into :: (KnownTy a, NotSum a) => Flow IntoS a 'Nothing 'Result
    {- | Series: an exit of either side exits the whole. Law: associative,
    @(f :> g) :> h = f :> (g :> h)@.
    -}
    (:>) :: Flow f a e1 b -> Flow g b e2 c -> Flow (f :>> g) a (Join e1 e2) c
    {- | A step, or a 'Fork' of a step, whose events spend a budget, its
    step's 'Meter': at most the limit at the run's Fuel, then what 'AtCap'
    says. A step with no 'Meter' cannot be capped, nor can any other flow
    ('CapTarget'). Law: it walks as the step or the fork, with a cap.
    -}
    Capped :: PerFuel Limit -> AtCap -> CapTarget c i e o -> Flow (CappedS c) i e o
    {- | Repeat the body while it continues; its exit is the loop's out. Over
    one type only: a loop over a sum would start each round at one of
    several states, and the exit of a sum would not say which summand. Its
    body holds a 'Capped' step of its own, which bounds it ('graph' refuses
    one that does not). Law, Elgot's fixpoint: the loop is its body unrolled
    once, @Loop n f = Catch (f :> Loop n f)@.
    -}
    Loop ::
        (NotSum a, NotSum b) =>
        Name -> Flow f a ('Just b) a -> Flow (LoopS f) a 'Nothing b
    {- | The copairing: each summand runs its branch, the branch of its
    label, so a branch missing or out of the sum's order does not compile.
    Laws, read off a step @t@ into the sum: beta, @t@'s edge @l@ walks as
    branch @l@; fusion, @Case bs :> h = Case (each b :> h)@.
    -}
    Case :: Branches bs ss e c -> Flow (CaseS bs) ('Sum ss) e c
    {- | Leave by the exit: the innermost 'Catch' or 'Loop' goes on from
    here. Uncaught, the flow's exit type is not 'Nothing', which a whole
    flow must be. Law: @Catch (Exit) = Id@.
    -}
    Exit :: Flow ExitS b ('Just b) c
    {- | The body once per item, in order, in this run: #351's @map@.
    Law: a fold over the list, the body's states drawn once, its out going
    back to its first state for the next item; @<first>.each_done@ leaves.
    -}
    Each ::
        (KnownTy a, KnownTy b, NotSum a, NotSum b) =>
        Flow f a 'Nothing b -> Flow (EachS f) ('List a) 'Nothing ('List b)
    {- | Start the body as a child run in the group, and go on with the
    input: the child runs beside the parent. One state, the group's, its
    @spawned@ event the edge on. The body is not drawn: it is the child's
    own run. Law: every way out of the flow from here passes an 'Await' of
    the group (structured concurrency), else 'State.Category.Graph.graph'
    refuses the flow.
    -}
    Fork ::
        (KnownTy a, KnownTy b, NotSum a) =>
        Group b -> Flow f a 'Nothing b -> Flow (ForkS f) a 'Nothing a
    {- | Wait for every child of the group to hand back: their results, in
    the order they were forked. One state, the group's: @handed_back@ stays,
    @done@ goes on. Law: @parallel g f = Each (Fork g f) :> Await g@ is
    @traverse f@ on the list.
    -}
    Await ::
        (KnownTy a, KnownTy b, NotSum a) => Group b -> Flow AwaitS a 'Nothing ('List b)
    {- | The codiagonal @b + b -> b@: the exit goes on as the out. Laws:
    @Catch (f :> g) = f :> Catch g@ for an @f@ with no exit, and
    @Catch (Case bs) = Case (each b, Catch b)@.
    -}
    Catch :: (NotSum b) => Flow f a ('Just b) b -> Flow (CatchS f) a 'Nothing b
    {- | The body's states, loops, skips and groups named @scope/name@, so
    a flow can sit twice in one graph. The root is unprefixed. Laws:
    @Scope s (f :> g) = Scope s f :> Scope s g@, and
    @Scope s (Scope t f) = Scope (s/t) f@.
    -}
    Scope :: Name -> Flow f i e o -> Flow (ScopeS f) i e o
    {- | The body, with its @eff@ handled by the handler: drawn as the body,
    so a graph and a states table do not see it. A whole flow handles each
    effect its steps raise ('Effects'). Law: @Handle h f@ draws as @f@.
    -}
    Handle :: Handler eff -> Flow f i e o -> Flow (HandleS eff f) i e o

infixr 5 :>

{- | A 'Case''s branches, one per summand, in the sum's order: the shape of
sop-core's @NP@, each branch labelled. A branch may be a series without
parentheses (@:>@ binds tighter):
@Case (#small :-> Do Describe :& #big :-> Do Implement :> Do Describe :& End)@.
-}
data Branches (bs :: [Shape]) (ss :: [(Symbol, Ty)]) (e :: Maybe Ty) (c :: Ty) where
    End :: Branches '[] '[] 'Nothing c
    (:&) ::
        Branch f l a e1 c ->
        Branches bs ss e2 c ->
        Branches (f ': bs) ('(l, a) ': ss) (Join e1 e2) c

infixr 3 :&

-- | The branch of summand @l@: the flow its input runs.
data Branch (f :: Shape) (l :: Symbol) (a :: Ty) (e :: Maybe Ty) (c :: Ty) where
    (:->) :: (KnownSymbol l) => Label l -> Flow f a e c -> Branch f l a e c

infixr 4 :->

-- | Each branch's flow, in the sum's order, through a function of any branch.
branchesWith :: (forall f a e1. Flow f a e1 c -> r) -> Branches bs ss e c -> [r]
branchesWith f = \case
    End -> []
    (_ :-> branch) :& rest -> f branch : branchesWith f rest

-- | A summand's label as a value: @#small@.
data Label (l :: Symbol) = Label
    deriving stock (Show)

instance (l ~ l') => IsLabel l (Label l') where
    fromLabel = Label

{- | The children a 'Fork' starts and an 'Await' waits for, each ending in
a @b@, and the role that runs each: an agent of that role, or a child run of
the flow that role leads. A group is a name, like a loop's; its 'Await'
waits on the run's open children of its role ("State.Run.Fold"'s ledger).
-}
data Group (b :: Ty) = Group Name AgentRole
    deriving stock (Eq, Show)

-- | A subagent's role, as @state handback <role>@ names it: @implementer@.
newtype AgentRole = AgentRole Text
    deriving stock (Eq, Show)

roleText :: AgentRole -> Text
roleText (AgentRole name) = name

{- | What 'Capped' may wrap: one step, as 'Do' draws it, or a 'Fork' of
one step, whose cap counts the children it starts. No other flow has a
meter, so capping one does not compile.
-}
data CapTarget (c :: Shape) (i :: Ty) (e :: Maybe Ty) (o :: Ty) where
    Step ::
        (StepSet k, Meter s, Sig s ~ '(i, e, o), KnownTy i, KnownTy o, NotSum i) =>
        Sing (s :: k) -> CapTarget (DoS s) i e o
    ForkOf ::
        (StepSet k, Meter s, Sig s ~ '(a, 'Nothing, b), KnownTy a, KnownTy b, NotSum a) =>
        Group b -> Sing (s :: k) -> CapTarget (ForkS (DoS s)) a 'Nothing a

deriving stock instance Show (CapTarget c i e o)

deriving stock instance Show (Flow s i e o)

deriving stock instance Show (Branches bs ss e c)

deriving stock instance Show (Branch f l a e c)

{- | A loop's, skip's, group's or scope's name. A group's is its 'Await''s state's
too; a scope's prefixes every name inside it.
-}
newtype Name = Name Text
    deriving stock (Eq, Ord, Show)
    deriving newtype (IsString)

nameText :: Name -> Text
nameText (Name name) = name

-- | @scope/name@: a name inside a scope.
scoped :: Name -> Name -> Name
scoped (Name scope) (Name name) = Name (scope <> "/" <> name)

{- | The scopes a state sits in, outermost first: the root's is empty, and
nesting is '<>', so @Scope s (Scope t f)@ puts @f@ in @scopePath s <> scopePath t@.
No scope's name holds a @/@: 'scopePath' splits one that does, so a path
has one spelling and reads back as it was written.
-}
newtype ScopePath = ScopePath [Name]
    deriving stock (Eq, Ord, Show)
    deriving newtype (Semigroup, Monoid)

-- | The scopes, outermost first.
scopeNames :: ScopePath -> [Name]
scopeNames (ScopePath scopes) = scopes

-- | A scope's name as a path: @Scope "s/t"@ is @Scope "s" (Scope "t" ..)@ (law Nested scopes).
scopePath :: Name -> ScopePath
scopePath (Name name) = ScopePath (map Name (Text.splitOn "/" name))

{- | @s/t/review@: a state's name inside its scopes, as people and the log
read it. An action of the monoid: @qualify (s <> t) = qualify s . qualify t@.
-}
qualify :: ScopePath -> StateName -> StateName
qualify scope (StateName name) = StateName (qualifyText scope name)

-- | A name inside its scopes, as the wire spells it: 'unqualify' reads it back.
qualifyText :: ScopePath -> Text -> Text
qualifyText (ScopePath scopes) name = Text.intercalate "/" (map nameText scopes <> [name])

-- | @s/review.rows@: an event of a state inside its scopes.
qualifyEvent :: ScopePath -> EventName -> EventName
qualifyEvent scope (EventName state outcome) = EventName (qualify scope state) outcome

{- | The scopes a qualified name sits in, and its name inside them: the
inverse of 'qualify' on a name with no @/@, as every step's and event's is.
-}
unqualify :: Text -> (ScopePath, Text)
unqualify qualified = case Text.breakOnEnd "/" qualified of
    ("", name) -> (mempty, name)
    (scopes, name) -> (scopePath (Name (Text.dropEnd 1 scopes)), name)

-- | The pick that leaves a 'State.Flow.Combinator.choiceLoop': @gather.enough@.
enoughOutcome :: OutcomeName
enoughOutcome = OutcomeName "enough"

-- | The one state a name draws: a pick's, or a group's 'Await'.
namedState :: Name -> StateName
namedState = StateName . nameText

{- | The events at a group's state: a child is spawned or hands back while
the run stays there; the group is done when it leaves.
-}
data FanEvent = Spawns | HandsBack | Leaves
    deriving stock (Eq, Show, Enum, Bounded)

-- | @engineers.spawned@: the graph's name for a group's event.
fanEvent :: FanEvent -> StateName -> EventName
fanEvent event fan =
    EventName fan $ case event of
        Spawns -> spawnedOutcome
        HandsBack -> handedBackOutcome
        Leaves -> OutcomeName "done"
