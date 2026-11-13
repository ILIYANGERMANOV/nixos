{-# LANGUAGE TypeData #-}

-- | The steps that propose a plan: write it, simplify it, weigh an alternative, confirm it.
module State.Step.Plan (
    PlanStep,
    Sing (..),
    Outcome (..),
) where

import Data.Aeson ((.:), (.=))
import Data.Type.Equality ((:~:) (..))
import State.Category.Step
import State.Category.Ty (Ty (..))

type data PlanStep = PlanS | SimplifyP | Alternative | Confirm

instance StepSet PlanStep where
    type Sig PlanS = '( 'Ctx, 'Nothing, 'Plan)
    type Sig SimplifyP = '( 'Plan, 'Nothing, 'Plan)
    type Sig Alternative = '( 'Plan, 'Nothing, 'Plan)
    type Sig Confirm = '( 'Plan, 'Just 'Plan, 'Ctx)
    type Drawn s = 'True

    data Sing s where
        PlanS :: Sing PlanS
        SimplifyP :: Sing SimplifyP
        Alternative :: Sing Alternative
        Confirm :: Sing Confirm

    data Outcome s l where
        -- \| The plan file.
        PlanDone :: FilePath -> Outcome PlanS 'Continued
        SimplifyPlanDone :: Outcome SimplifyP 'Continued
        SimplifyPlanSkipped :: Outcome SimplifyP 'Skipped
        AlternativeDone :: Outcome Alternative 'Continued
        AlternativeSkipped :: Outcome Alternative 'Skipped
        ConfirmConfirmed :: Outcome Confirm 'Exited
        ConfirmAdjusted :: Outcome Confirm 'Continued

    layerSteps = [SomeStep PlanS, SomeStep SimplifyP, SomeStep Alternative, SomeStep Confirm]
      where
        _listsEvery :: Sing (s :: PlanStep) -> ()
        _listsEvery = \case
            PlanS -> ()
            SimplifyP -> ()
            Alternative -> ()
            Confirm -> ()

    stepName =
        StateName . \case
            PlanS -> "plan"
            SimplifyP -> "simplify_plan"
            Alternative -> "alternative"
            Confirm -> "confirm"

    outcomes = \case
        PlanS -> Continues (OutcomeName "done")
        SimplifyP -> Continues (OutcomeName "done")
        Alternative -> Continues (OutcomeName "done")
        Confirm -> ExitsOr (OutcomeName "confirmed") (OutcomeName "adjusted")

    special = \case
        PlanS -> Ordinary
        SimplifyP -> Ordinary
        Alternative -> Ordinary
        Confirm -> AsksConfirm

    sameStep a b = case (a, b) of
        (PlanS, PlanS) -> Just Refl
        (SimplifyP, SimplifyP) -> Just Refl
        (Alternative, Alternative) -> Just Refl
        (Confirm, Confirm) -> Just Refl
        _ -> Nothing

    pack = \case
        o@(PlanDone _) -> packed PlanS o
        o@SimplifyPlanDone -> packed SimplifyP o
        o@SimplifyPlanSkipped -> packed SimplifyP o
        o@AlternativeDone -> packed Alternative o
        o@AlternativeSkipped -> packed Alternative o
        o@ConfirmConfirmed -> packed Confirm o
        o@ConfirmAdjusted -> packed Confirm o

    encodeOutcome = \case
        PlanDone path -> "path" .= path
        SimplifyPlanDone -> mempty
        SimplifyPlanSkipped -> mempty
        AlternativeDone -> mempty
        AlternativeSkipped -> mempty
        ConfirmConfirmed -> mempty
        ConfirmAdjusted -> mempty

    decoders =
        [ Decoder PlanS (\obj -> PlanDone <$> obj .: "path")
        , Decoder SimplifyP (const (pure SimplifyPlanDone))
        , Decoder SimplifyP (const (pure SimplifyPlanSkipped))
        , Decoder Alternative (const (pure AlternativeDone))
        , Decoder Alternative (const (pure AlternativeSkipped))
        , Decoder Confirm (const (pure ConfirmConfirmed))
        , Decoder Confirm (const (pure ConfirmAdjusted))
        ]

deriving stock instance Show (Sing (s :: PlanStep))
deriving stock instance Show (Outcome (s :: PlanStep) l)
deriving stock instance Eq (Outcome (s :: PlanStep) l)
