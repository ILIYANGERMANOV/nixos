{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeData #-}
{-# LANGUAGE UndecidableInstances #-}

{- | The agent's pick of one labelled branch: the step a
'State.Flow.Library.choice' runs before its 'State.Category.Flow.Case'. Its one
state is the pick's name, its events @<name>.<label>@, one per branch, each
going on with the input unchanged. The pick only decides; the branch it
names does the work, as steps of their own.
-}
module State.Step.Pick (
    PickStep (..),
    -- Named, not @(..)@: a data family's @(..)@ would export every layer's constructors in scope here.
    Sing (Pick),
    Outcome (Picked),
    Over,
    PickLabels,
    pickOutcomes,
) where

import Data.Kind (Constraint)
import Data.Typeable (Typeable)
import GHC.TypeLits (KnownSymbol, Symbol)
import State.Category.Effect (Eff (..))
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
    type Raises s = '[PickE]

    type Sig (Pick a ss) = '(a, 'Nothing, 'Sum ss)

    data Sing s where
        Pick :: (KnownTy a, NotSum a, Summands ss, Over a ss, PickLabels ss ss, Typeable a, Typeable ss) => Name -> Sing (Pick a ss)

    data Outcome s l where
        -- \| The branch labelled @l@ goes on.
        Picked :: (KnownSymbol l, HasLabel l ss ~ 'True) => Sing (Pick a ss) -> Outcome (Pick a ss) ('Took l)

    -- No row: each flow names its own picks, so no pick belongs to the layer.
    layerSteps = []

    stepName (Pick name) = namedState name

    outcomes (Pick _) = Branches

    special (Pick _) = Ordinary

    pack = \case
        o@(Picked pick@(Pick _)) -> packed pick o

    encodeOutcome (Picked _) = mempty

    -- None: a pick's events are its flow's labels, read where the flow is known.
    decoders = []

{- | Every outcome of the pick, one per label, in the sum's order: what a
run may record at it. Its flow names its labels, so the layer has no reader
of its own ('decoders').
-}
pickOutcomes :: Sing (s :: PickStep) -> [SomeOutcome PickStep]
pickOutcomes = \case
    p@(Pick @_ @ss _) -> labelOutcomes @ss @ss p

{- | The outcomes of the labels @ss@ of the pick into @all@: one per label,
each with the proof its label is one of @all@'s, found where @all@ is known.
-}
type PickLabels :: [(Symbol, Ty)] -> [(Symbol, Ty)] -> Constraint
class PickLabels all ss where
    labelOutcomes :: Sing (Pick a all) -> [SomeOutcome PickStep]

instance PickLabels all '[] where
    labelOutcomes _ = []

instance (KnownSymbol l, HasLabel l all ~ 'True, PickLabels all ss) => PickLabels all ('(l, b) ': ss) where
    labelOutcomes p@(Pick _) = packed p (picked @l p) : labelOutcomes @all @ss p

-- | The outcome of label @l@: its type names the label, which the pick's argument does not.
picked :: forall l a ss. (KnownSymbol l, HasLabel l ss ~ 'True) => Sing (Pick a ss) -> Outcome (Pick a ss) ('Took l)
picked = Picked

deriving stock instance Show (Sing (s :: PickStep))
deriving stock instance Eq (Sing (s :: PickStep))
deriving stock instance Show (Outcome (s :: PickStep) l)
deriving stock instance Eq (Outcome (s :: PickStep) l)
