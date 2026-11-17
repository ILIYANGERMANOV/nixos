{-# LANGUAGE TypeData #-}
{-# LANGUAGE UndecidableInstances #-}

{- | The agent's pick of one labelled branch: the step a
'State.Flow.Library.choice' runs before its 'State.Category.Flow.Case'. Its one
state is the pick's name, its events @<name>.<label>@, one per branch, each
going on with the input unchanged. The pick only decides; the branch it
names does the work, as steps of their own.
-}
module State.Step.Pick (
    PickStep,
    -- Named, not @(..)@: a data family's @(..)@ would export every layer's constructors in scope here.
    Sing (Pick),
    Outcome (Picked),
    Over,
) where

import Data.Kind (Constraint)
import Data.Type.Equality ((:~:) (..))
import Data.Typeable (Typeable, eqT)
import GHC.TypeLits (KnownSymbol, Symbol)
import State.Category.Flow (Name, namedState)
import State.Category.Step
import State.Category.Ty (HasLabel, KnownTy, NotSum, Summands, Ty, TyOf (..))

{- | A pick from an @a@ into the summands @ss@, each an @a@ again: which
labels it offers is its type, so a 'State.Category.Flow.Case' after it
must branch on each.
-}
type data PickStep = Pick Ty [(Symbol, Ty)]

-- | Every summand is of type @a@: a pick hands its input on unchanged.
type Over :: Ty -> [(Symbol, Ty)] -> Constraint
type family Over a ss where
    Over a '[] = ()
    Over a ('(l, b) ': ss) = (a ~ b, Over a ss)

instance StepSet PickStep where
    type Sig (Pick a ss) = '(a, 'Nothing, 'Sum ss)
    type Drawn s = 'True

    data Sing s where
        Pick :: (KnownTy a, NotSum a, Summands ss, Over a ss, Typeable a, Typeable ss) => Name -> Sing (Pick a ss)

    data Outcome s l where
        -- \| The branch labelled @l@ goes on.
        Picked :: (KnownSymbol l, HasLabel l ss ~ 'True) => Sing (Pick a ss) -> Outcome (Pick a ss) ('Took l)

    -- No row: each flow names its own picks, so no pick belongs to the layer.
    layerSteps = []

    stepName (Pick name) = namedState name

    outcomes (Pick _) = Branches

    special (Pick _) = Ordinary

    sameStep (Pick @a @ss _) (Pick @b @ts _) = do
        Refl <- eqT @a @b
        Refl <- eqT @ss @ts
        pure Refl

    pack = \case
        o@(Picked pick) -> packed pick o

    encodeOutcome (Picked _) = mempty

    -- None: a pick's events are its flow's labels, read where the flow is known.
    decoders = []

deriving stock instance Show (Sing (s :: PickStep))
deriving stock instance Eq (Sing (s :: PickStep))
deriving stock instance Show (Outcome (s :: PickStep) l)
deriving stock instance Eq (Outcome (s :: PickStep) l)
