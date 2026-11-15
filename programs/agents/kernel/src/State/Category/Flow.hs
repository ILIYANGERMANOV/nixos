{- | #351's category @Flow@: typed terms over the steps of "State.Category.Step"'s layers. The
indexes make an ill-typed gluing a compile error (law Typed gluing), and 'Opt'
and 'Loop' exist only on the shapes #351 allows (law Skip is endo). Every
budget is a 'Capped' step's meter (decision 13). A flow
is built by composing small flows ("State.Flow.Library"), each reusable in
any flow.
-}
module State.Category.Flow (
    Flow (..),
    inl,
    inr,
    (|||),
    alternateLoop,
    Join,
    Name (..),
    nameText,
    scoped,
    ScopePath,
    scopePath,
    qualify,
    qualifyEvent,
    unqualify,
    fanName,
    FanEvent (..),
    fanEvent,
) where

import Data.List.NonEmpty (NonEmpty)
import Data.String (IsString)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.TypeError (ErrorMessage (..), TypeError)
import State.Category.Fuel (PerFuel, SkipWhen)
import State.Category.Meter (AtCap, Limit, Meter)
import State.Category.Step (EventName (..), OutcomeName (..), StateName (..), StepSet (..))
import State.Category.Ty (KnownTy, NotSum, Ty (..))

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

{- | @i@: in. @e@: the exit, if any. @o@: continue. Each constructor's
comment states its law, read off the graph a run walks ("State.Category.Graph").
A loop, skip or fan-out is known by its 'Name'; a budget is a 'Capped'
step, carrying its limits as 'PerFuel' data: no global table of ids.
-}
data Flow (i :: Ty) (e :: Maybe Ty) (o :: Ty) where
    {- | One step, of any layer: its signature is the term's type. A step takes
    one type, never a sum. Law: one state, one edge per outcome.
    -}
    Do :: (StepSet k, Drawn s ~ 'True, Sig s ~ '(i, e, o), KnownTy i, KnownTy o, NotSum i) => Sing (s :: k) -> Flow i e o
    -- | Identity: no step runs. Law: @Id :> f = f = f :> Id@.
    Id :: Flow a 'Nothing a
    {- | Series: an exit of either side exits the whole. Law: associative,
    @(f :> g) :> h = f :> (g :> h)@.
    -}
    (:>) :: Flow a e1 b -> Flow b e2 c -> Flow a (Join e1 e2) c
    {- | One step whose events spend a budget, its step's 'Meter': at most
    the limit at the run's Fuel, then what 'AtCap' says. A step with no
    'Meter' cannot be capped. Law: it walks as @Do s@, one state with a cap.
    -}
    Capped :: (StepSet k, Meter s, Drawn s ~ 'True, Sig s ~ '(i, e, o), KnownTy i, KnownTy o, NotSum i) => PerFuel Limit -> AtCap -> Sing (s :: k) -> Flow i e o
    {- | Repeat the body while it continues; its exit is the loop's out. Over
    one type only: a loop over a sum would start each round at one of
    several states, and the exit of a sum would not say which summand. Its
    body holds a 'Capped' step of its own, which bounds it ('graph' refuses
    one that does not). Law, Elgot's fixpoint: the loop is its body unrolled
    once, @Loop n f = Catch (f :> Loop n f)@.
    -}
    Loop :: (NotSum a, NotSum b) => Name -> Flow a ('Just b) a -> Flow a 'Nothing b
    {- | A mark: the level may skip the body, so it must keep the type. Over
    one type only: a skip is one edge, and a sum would need one per summand.
    Law: a skip walks as 'Id'; at a level that never skips, the body alone.
    -}
    Opt :: (NotSum a) => Name -> PerFuel SkipWhen -> Flow a 'Nothing a -> Flow a 'Nothing a
    -- | One flow per item, as child runs. Law: one state, its children's events stay there.
    Par :: (KnownTy a, KnownTy b) => Name -> Flow a 'Nothing b -> Flow ('List a) 'Nothing ('List b)
    -- | Into the left summand: no step runs, the next block's left branch does.
    InL :: Flow a 'Nothing (a ':+ b)
    -- | Into the right summand.
    InR :: Flow b 'Nothing (a ':+ b)
    {- | Case: the left branch on the left summand, the right on the right.
    Laws: @inl :> (f ||| g) = f@, @inr :> (f ||| g) = g@, and
    @(inl :> h) ||| (inr :> h) = h@.
    -}
    (:|||) :: Flow a e1 c -> Flow b e2 c -> Flow (a ':+ b) (Join e1 e2) c
    {- | The codiagonal @b + b -> b@: the exit goes on as the out. Laws:
    @Catch (f :> g) = f :> Catch g@ for an @f@ with no exit, and
    @Catch (f ||| g) = Catch f ||| Catch g@.
    -}
    Catch :: (NotSum b) => Flow a ('Just b) b -> Flow a 'Nothing b
    {- | The body's states, loops, skips and fan-outs named @scope/name@, so
    a flow can sit twice in one graph. The root is unprefixed. Laws:
    @Scope s (f :> g) = Scope s f :> Scope s g@, and
    @Scope s (Scope t f) = Scope (s/t) f@.
    -}
    Scope :: Name -> Flow i e o -> Flow i e o

infixr 5 :>

infixr 4 :|||

{- | #351's names for the injections and the case. A branch may be a series
without parentheses (@:>@ binds tighter), a case after a step needs them:
@Do Triage :> (f ||| g :> h)@.
-}
inl :: Flow a 'Nothing (a ':+ b)
inl = InL

inr :: Flow b 'Nothing (a ':+ b)
inr = InR

(|||) :: Flow a e1 c -> Flow b e2 c -> Flow (a ':+ b) (Join e1 e2) c
(|||) = (:|||)

infixr 4 |||

{- | The steps in a fixed order, round after round: a loop over their series.
Law: @alternateLoop n (f :| [g]) = Loop n (f :> g)@.
-}
alternateLoop :: (NotSum a, NotSum b) => Name -> NonEmpty (Flow a ('Just b) a) -> Flow a 'Nothing b
alternateLoop name = Loop name . foldr1 (:>)

deriving stock instance Show (Flow i e o)

{- | A loop's, skip's, fan-out's or scope's name. A fan-out's is its state's
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

-- | A scope's name as a path: @Scope "s/t"@ is @Scope "s" (Scope "t" ..)@ (law Nested scopes).
scopePath :: Name -> ScopePath
scopePath (Name name) = ScopePath (map Name (Text.splitOn "/" name))

{- | @s/t/review@: a state's name inside its scopes, as people and the log
read it. An action of the monoid: @qualify (s <> t) = qualify s . qualify t@.
-}
qualify :: ScopePath -> StateName -> StateName
qualify (ScopePath scopes) (StateName name) = StateName (Text.intercalate "/" (map nameText scopes <> [name]))

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

-- | The state a 'Par' draws as: its fan-out's name.
fanName :: Name -> StateName
fanName = StateName . nameText

{- | The events at a fan-out's state: a child is spawned or hands back while
the run stays there; the fan-out is done when it leaves.
-}
data FanEvent = Spawns | HandsBack | Leaves
    deriving stock (Eq, Show, Enum, Bounded)

-- | @engineers.spawned@: the graph's name for a fan-out's event.
fanEvent :: FanEvent -> StateName -> EventName
fanEvent event fan =
    EventName fan . OutcomeName $ case event of
        Spawns -> "spawned"
        HandsBack -> "handed_back"
        Leaves -> "done"
