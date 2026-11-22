{-# LANGUAGE TypeData #-}

{- | The steps that read the run's Fuel: 'Fuel' sets it, and 'Skip' picks
whether an optional block runs at it ('State.Flow.Combinator.skippable'). The kernel
decides a skip from the Fuel when the level may skip, as its 'PerFuel'
'SkipWhen' says, so a skip is a pick no agent makes by guessing.
-}
module State.Step.Fuel (
    FuelStep (..),
    -- Named, not @(..)@: a data family's @(..)@ would export every layer's constructors in scope here.
    Sing (Fuel, Skip),
    Outcome (LevelSet, Skipping, Running),
    SkipOrRun,
    skipOutcomes,
) where

import Data.Aeson ((.:), (.=))
import Data.Typeable (Typeable)
import State.Category.Flow (Name, nameText)
import State.Category.Fuel (PerFuel, SkipWhen, fuelName)
import State.Category.Fuel qualified as Level
import State.Category.Step
import State.Category.Ty (KnownTy, NotSum, Ty, TyOf (..))

{- | 'Fuel' sets the level, at the request's start, where its context is
all there is. 'Skip' sits before an optional block over any one type.
-}
type data FuelStep = Fuel | Skip Ty

-- | The two branches of a skip: past the block, or into it.
type SkipOrRun a = '[ '("skip", a), '("run", a)]

instance StepSet FuelStep where
    type Raises s = '[]

    type Sig Fuel = '( 'Ctx, 'Nothing, 'Ctx)
    type Sig (Skip a) = '(a, 'Nothing, 'Sum (SkipOrRun a))

    data Sing s where
        Fuel :: Sing Fuel
        -- \| Named after the block it may skip, with the levels that may: its state is @skip_<block>@.
        Skip ::
            (KnownTy a, NotSum a, Typeable a) => Name -> PerFuel SkipWhen -> Sing (Skip a)

    data Outcome s l where
        -- \| The run's Fuel, from here on.
        LevelSet :: Level.Fuel -> Outcome Fuel 'Continued
        -- \| The block is skipped: the input goes on past it.
        Skipping :: Sing (Skip a) -> Outcome (Skip a) ('Took "skip")
        -- \| The block runs.
        Running :: Sing (Skip a) -> Outcome (Skip a) ('Took "run")

    -- 'Fuel' has its row in @flows/steps.nix@; each optional block names its own skip.
    layerSteps = [SomeStep Fuel]

    stepName = \case
        Fuel -> StateName "fuel"
        Skip name _ -> StateName ("skip_" <> nameText name)

    outcomes = \case
        Fuel -> Continues (OutcomeName "set")
        Skip _ _ -> Branches

    pack = \case
        o@(LevelSet _) -> packed Fuel o
        o@(Skipping skip@(Skip _ _)) -> packed skip o
        o@(Running skip@(Skip _ _)) -> packed skip o

    encodeOutcome = \case
        LevelSet level -> "level" .= fuelName level
        Skipping _ -> mempty
        Running _ -> mempty

    -- A skip's events are its block's, read where the flow is known ('skipOutcomes').
    decoders =
        [ Decoder
            Fuel
            ( \o ->
                LevelSet
                    <$> (o .: "level" >>= maybe (fail "no such level") pure . Level.parseFuel)
            )
        ]

{- | A skip's two outcomes, which a run may record at it: its block names
the skip, so the layer has no reader of them ('decoders'). 'Fuel''s carries
a level, which its reader reads.
-}
skipOutcomes :: Sing (s :: FuelStep) -> [SomeOutcome FuelStep]
skipOutcomes = \case
    Fuel -> []
    skip@(Skip _ _) -> [pack (Skipping skip), pack (Running skip)]

deriving stock instance Show (Sing (s :: FuelStep))
deriving stock instance Eq (Sing (s :: FuelStep))
deriving stock instance Show (Outcome (s :: FuelStep) l)
deriving stock instance Eq (Outcome (s :: FuelStep) l)
