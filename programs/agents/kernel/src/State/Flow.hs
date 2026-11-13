{- | #351's category @Flow@: typed terms over the steps of "State.Cap". The
indexes make an ill-typed gluing a compile error (law Typed gluing), and 'Opt'
and 'Loop' exist only on the shapes #351 allows (law Skip is endo).
-}
module State.Flow (
    Flow (..),
    Join,
    OnEmpty (..),
    LoopId (..),
    OptId (..),
    FanId (..),
    fanName,
) where

import Data.Kind (Type)
import GHC.TypeError (ErrorMessage (..), TypeError)
import State.Cap (KnownTy, StateName (..), Step, Ty (..))

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
are not numbers in the term: 'State.Mode.cfg' gives each id its value.
-}
data Flow (i :: Ty) (e :: Maybe Ty) (o :: Ty) where
    Do :: (KnownTy i, KnownTy o) => Step i e o -> Flow i e o
    -- | Series: an exit of either side exits the whole.
    (:>) :: Flow a e1 b -> Flow b e2 c -> Flow a (Join e1 e2) c
    -- | Repeat the body while it continues; its exit is the loop's out.
    Loop :: LoopId -> OnEmpty a b -> Flow a ('Just b) a -> Flow a 'Nothing b
    -- | A mark: the mode may skip the body, so it must keep the type.
    Opt :: OptId -> Flow a 'Nothing a -> Flow a 'Nothing a
    -- | One flow per item, as child runs.
    Par :: (KnownTy a, KnownTy b) => FanId -> Flow a 'Nothing b -> Flow ('List a) 'Nothing ('List b)

infixr 5 :>

deriving stock instance Show (Flow i e o)

data LoopId = LGather | LPlan | LReview | LCi
    deriving stock (Eq, Ord, Show, Enum, Bounded)

data OptId = ORes | OSimp | OAlt | ORefactor | OBody | OReady
    deriving stock (Eq, Ord, Show, Enum, Bounded)

data FanId = FResearchers | FEngineers
    deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The state a 'Par' draws as.
fanName :: FanId -> StateName
fanName =
    StateName . \case
        FResearchers -> "researchers"
        FEngineers -> "engineers"
