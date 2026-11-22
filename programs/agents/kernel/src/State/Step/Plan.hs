{-# LANGUAGE TypeData #-}

-- | The steps that propose a plan: write it, refine it, present it, confirm it.
module State.Step.Plan (
    PlanStep (..),
    Sing (..),
    Outcome (..),
    refineName,
) where

import Data.Aeson ((.:), (.=))
import State.Category.Effect (OpOf (Confirms))
import State.Category.Flow (Name)
import State.Category.Meter (Meter (..), Spend (..))
import State.Category.Step
import State.Category.Ty (TyOf (..))

type data PlanStep = PlanS | SimplifyP | StandardsP | AlignP | Present | Confirm

instance StepSet PlanStep where
    type Raises PlanS = '[]
    type Raises SimplifyP = '[]
    type Raises StandardsP = '[]
    type Raises AlignP = '[]
    type Raises Present = '[]
    type Raises Confirm = '[ 'Confirms "the presented plan"]

    type Sig PlanS = '( 'Ctx, 'Nothing, 'Plan)
    type Sig SimplifyP = '( 'Plan, 'Nothing, 'Plan)
    type Sig StandardsP = '( 'Plan, 'Nothing, 'Plan)
    type Sig AlignP = '( 'Plan, 'Nothing, 'Plan)
    type Sig Present = '( 'Plan, 'Nothing, 'Plan)
    type Sig Confirm = '( 'Plan, 'Just 'Plan, 'Ctx)

    data Sing s where
        PlanS :: Sing PlanS
        SimplifyP :: Sing SimplifyP
        StandardsP :: Sing StandardsP
        AlignP :: Sing AlignP
        Present :: Sing Present
        Confirm :: Sing Confirm

    data Outcome s l where
        -- \| The plan file.
        PlanDone :: FilePath -> Outcome PlanS 'Continued
        SimplifyPlanDone :: Outcome SimplifyP 'Continued
        StandardsPlanDone :: Outcome StandardsP 'Continued
        AlignPlanDone :: Outcome AlignP 'Continued
        PresentDone :: Outcome Present 'Continued
        ConfirmConfirmed :: Outcome Confirm 'Exited
        ConfirmAdjusted :: Outcome Confirm 'Continued

    layerSteps =
        [ SomeStep PlanS
        , SomeStep SimplifyP
        , SomeStep StandardsP
        , SomeStep AlignP
        , SomeStep Present
        , SomeStep Confirm
        ]
      where
        _listsEvery :: Sing (s :: PlanStep) -> ()
        _listsEvery = \case
            PlanS -> ()
            SimplifyP -> ()
            StandardsP -> ()
            AlignP -> ()
            Present -> ()
            Confirm -> ()

    stepName =
        StateName . \case
            PlanS -> "plan"
            SimplifyP -> "simplify_plan"
            StandardsP -> "standards_plan"
            AlignP -> "align_plan"
            Present -> "present"
            Confirm -> "confirm"

    outcomes = \case
        PlanS -> Continues (OutcomeName "done")
        SimplifyP -> Continues (OutcomeName "done")
        StandardsP -> Continues (OutcomeName "done")
        AlignP -> Continues (OutcomeName "done")
        Present -> Continues (OutcomeName "done")
        Confirm -> ExitsOr (OutcomeName "confirmed") (OutcomeName "adjusted")

    pack = \case
        o@(PlanDone _) -> packed PlanS o
        o@SimplifyPlanDone -> packed SimplifyP o
        o@StandardsPlanDone -> packed StandardsP o
        o@AlignPlanDone -> packed AlignP o
        o@PresentDone -> packed Present o
        o@ConfirmConfirmed -> packed Confirm o
        o@ConfirmAdjusted -> packed Confirm o

    encodeOutcome = \case
        PlanDone path -> "path" .= path
        SimplifyPlanDone -> mempty
        StandardsPlanDone -> mempty
        AlignPlanDone -> mempty
        PresentDone -> mempty
        ConfirmConfirmed -> mempty
        ConfirmAdjusted -> mempty

    decoders =
        [ Decoder PlanS (\obj -> PlanDone <$> obj .: "path")
        , Decoder SimplifyP (const (pure SimplifyPlanDone))
        , Decoder StandardsP (const (pure StandardsPlanDone))
        , Decoder AlignP (const (pure AlignPlanDone))
        , Decoder Present (const (pure PresentDone))
        , Decoder Confirm (const (pure ConfirmConfirmed))
        , Decoder Confirm (const (pure ConfirmAdjusted))
        ]

{- | The block of passes that refine a plan, its skip @skip_refine@. Named
here, as a plan settled without the user skips it at any Fuel
('State.Run.Fold.settledSkips'), which matches its skip by this name.
-}
refineName :: Name
refineName = "refine"

deriving stock instance Show (Sing (s :: PlanStep))
deriving stock instance Show (Outcome (s :: PlanStep) l)
deriving stock instance Eq (Outcome (s :: PlanStep) l)

-- | Each adjusted plan: another round of gathering and proposing.
instance Meter Confirm where
    meterName Confirm = "Plan rounds"
    spends Confirm = \case
        Ends _ ConfirmAdjusted -> 1
        Ends _ ConfirmConfirmed -> 0
        Asks -> 0
