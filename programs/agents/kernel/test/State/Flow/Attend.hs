{-# LANGUAGE TypeData #-}

{- | A step that raises 'FocusE', for the tests only: no flow raises it yet,
so a test that a whole flow must handle it needs a step of its own. Like
"State.Flow.Triage", it is in no catalog, no @steps.nix@ row and no wire format.
-}
module State.Flow.Attend (
    AttendStep (..),
    -- Named, not @(..)@: a data family's @(..)@ would export every layer's constructors in scope here.
    Sing (Attend),
    Outcome (Attended),
) where

import Data.Type.Equality ((:~:) (..))
import State.Category.Effect (Eff (..))
import State.Category.Step
import State.Category.Ty (TyOf (..))

type data AttendStep = Attend

instance StepSet AttendStep where
    type Raises s = '[FocusE, AskE]

    type Sig Attend = '( 'Ctx, 'Nothing, 'Ctx)

    data Sing s where
        Attend :: Sing Attend

    data Outcome s l where
        Attended :: Outcome Attend 'Continued

    layerSteps = [SomeStep Attend]

    stepName Attend = StateName "attend"

    outcomes Attend = Continues (OutcomeName "done")

    special Attend = Ordinary

    sameStep Attend Attend = Just Refl

    pack = \case
        o@Attended -> packed Attend o

    encodeOutcome = \case
        Attended -> mempty

    decoders = [Decoder Attend (const (pure Attended))]

deriving stock instance Show (Sing (s :: AttendStep))
deriving stock instance Show (Outcome (s :: AttendStep) l)
deriving stock instance Eq (Outcome (s :: AttendStep) l)
