{-# LANGUAGE TypeData #-}

{- | A step that raises 'FocusE', for the tests only: a test that a whole
flow must handle it needs a step no handled flow holds. Like
"State.Flow.Triage", it is in no catalog, no @steps.nix@ row and no wire format.
-}
module State.Flow.Attend (
    AttendStep (..),
    -- Named, not @(..)@: a data family's @(..)@ would export every layer's constructors in scope here.
    Sing (Attend),
    Outcome (Attended),
) where

import State.Category.Effect (OpOf (Focuses))
import State.Category.Step
import State.Category.Ty (TyOf (..))

type data AttendStep = Attend

instance StepSet AttendStep where
    type Raises s = '[ 'Focuses]

    type Sig Attend = '( 'Ctx, 'Nothing, 'Ctx)

    data Sing s where
        Attend :: Sing Attend

    data Outcome s l where
        Attended :: Outcome Attend 'Continued

    layerSteps = [SomeStep Attend]

    stepName Attend = StateName "attend"

    outcomes Attend = Continues (OutcomeName "done")

    pack = \case
        o@Attended -> packed Attend o

    encodeOutcome = \case
        Attended -> mempty

    decoders = [Decoder Attend (const (pure Attended))]

deriving stock instance Show (Sing (s :: AttendStep))
deriving stock instance Show (Outcome (s :: AttendStep) l)
deriving stock instance Eq (Outcome (s :: AttendStep) l)
