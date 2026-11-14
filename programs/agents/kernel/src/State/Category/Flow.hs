{- | #351's category @Flow@: typed terms over the steps of "State.Category.Step"'s layers. The
indexes make an ill-typed gluing a compile error (law Typed gluing), and 'Opt'
and 'Loop' exist only on the shapes #351 allows (law Skip is endo).
-}
module State.Category.Flow (
    Flow (..),
    inl,
    inr,
    (|||),
    Join,
    OnEmpty (..),
    LoopId (..),
    OptId (..),
    FanId (..),
    fanName,
    fanNamed,
    FanEvent (..),
    fanEvent,
    loopName,
) where

import Data.Kind (Type)
import Data.List (find)
import Data.Text (Text)
import GHC.TypeError (ErrorMessage (..), TypeError)
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

-- | What a 'Loop' does when its fuel runs out.
type OnEmpty :: Ty -> Ty -> Type
data OnEmpty a b where
    -- | Stop the run: out of fuel is a @stop fuel@.
    StopOut :: OnEmpty a b
    -- | Take the exit, as Review does: only when the exit is the loop's in type.
    ExitOut :: OnEmpty a a

deriving stock instance Show (OnEmpty a b)

{- | @i@: in. @e@: the exit, if any. @o@: continue. Fuel, skips and fan-out
are not numbers in the term: 'State.Category.Mode.cfg' gives each id its value.
-}
data Flow (i :: Ty) (e :: Maybe Ty) (o :: Ty) where
    -- | One step, of any layer: its signature is the term's type. A step takes one type, never a sum.
    Do :: (StepSet k, Drawn s ~ 'True, Sig s ~ '(i, e, o), KnownTy i, KnownTy o, NotSum i) => Sing (s :: k) -> Flow i e o
    -- | Series: an exit of either side exits the whole.
    (:>) :: Flow a e1 b -> Flow b e2 c -> Flow a (Join e1 e2) c
    {- | Repeat the body while it continues; its exit is the loop's out. Over
    one type only: a loop over a sum would start each round at one of
    several states, and the exit of a sum would not say which summand.
    -}
    Loop :: (NotSum a, NotSum b) => LoopId -> OnEmpty a b -> Flow a ('Just b) a -> Flow a 'Nothing b
    {- | A mark: the mode may skip the body, so it must keep the type. Over one
    type only: a skip is one edge, and a sum would need one per summand.
    -}
    Opt :: (NotSum a) => OptId -> Flow a 'Nothing a -> Flow a 'Nothing a
    -- | One flow per item, as child runs.
    Par :: (KnownTy a, KnownTy b) => FanId -> Flow a 'Nothing b -> Flow ('List a) 'Nothing ('List b)
    -- | Into the left summand: no step runs, the next block's left branch does.
    InL :: Flow a 'Nothing (a ':+ b)
    -- | Into the right summand.
    InR :: Flow b 'Nothing (a ':+ b)
    -- | Case: the left branch on the left summand, the right on the right.
    (:|||) :: Flow a e1 c -> Flow b e2 c -> Flow (a ':+ b) (Join e1 e2) c

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

deriving stock instance Show (Flow i e o)

data LoopId = LGather | LPlan | LReview | LCi
    deriving stock (Eq, Ord, Show, Enum, Bounded)

data OptId = ORes | OSimp | OAlt | ORefactor | OBody | OReady
    deriving stock (Eq, Ord, Show, Enum, Bounded)

data FanId = FResearchers | FEngineers
    deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The fan-out whose state this is, if any.
fanNamed :: StateName -> Maybe FanId
fanNamed name = find ((== name) . fanName) [minBound .. maxBound]

-- | The state a 'Par' draws as.
fanName :: FanId -> StateName
fanName =
    StateName . \case
        FResearchers -> "researchers"
        FEngineers -> "engineers"

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

loopName :: LoopId -> Text
loopName = \case
    LGather -> "gather"
    LPlan -> "plan"
    LReview -> "review"
    LCi -> "ci"
