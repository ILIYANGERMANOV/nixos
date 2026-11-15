{-# LANGUAGE TypeData #-}
{-# LANGUAGE UndecidableInstances #-}

{- | The 10x's steps around a fan-out: break the plan into tasks, leave
the fan-out once every task is settled, merge the PRs into one, or end the
round for the next. Each names its fan-out, so a run's fan-outs keep their
own tasks and children.
-}
module State.Step.Fan (
    FanStep,
    Sing (..),
    Outcome (..),
) where

import Data.Aeson ((.:))
import Data.Type.Equality ((:~:) (..))
import GHC.TypeError (ErrorMessage (..), TypeError)
import State.Category.Flow (FanEvent (Leaves), FanId, breakdownName, fanEvent, fanName, mergeName)
import State.Category.Step
import State.Category.Ty (Ty (..))
import State.Step.Artifact (Tasks, Url, breakdownOf, tasksData, urlData, urlOf)

{- | 'FanOut' is the state a 'State.Category.Flow.Par' draws, named by its
fan-out: a step of this layer for its outcome, never one 'State.Category.Flow.Do' draws.
-}
type data FanStep = Breakdown | FanOut | Merge

type DrawnFan :: FanStep -> Bool
type family DrawnFan s where
    DrawnFan FanOut = TypeError ('Text "A fan-out's state is drawn by Par, not Do")
    DrawnFan s = 'True

instance StepSet FanStep where
    type Sig Breakdown = '( 'Plan, 'Nothing, 'List 'Ctx)
    type Sig FanOut = '( 'List 'Ctx, 'Nothing, 'List 'PR)
    type Sig Merge = '( 'List 'PR, 'Just 'PR, 'Ctx)
    type Drawn s = DrawnFan s

    data Sing s where
        Breakdown :: FanId -> Sing Breakdown
        FanOut :: FanId -> Sing FanOut
        Merge :: FanId -> Sing Merge

    data Outcome s l where
        BreakdownDone :: FanId -> Tasks -> Outcome Breakdown 'Continued
        -- \| Every task of the fan-out is settled ("State.Run.Fan").
        FanDone :: FanId -> Outcome FanOut 'Continued
        -- \| The one PR the merge left: the run ends.
        MergeDone :: FanId -> Url -> Outcome Merge 'Exited
        -- \| The round ends with its PRs merged, parked or kept: the next one starts at gathering.
        MergeNextRound :: FanId -> Outcome Merge 'Continued

    layerSteps = concat [[SomeStep (Breakdown fan), SomeStep (Merge fan)] | fan <- [minBound .. maxBound]]
      where
        _listsEvery :: Sing (s :: FanStep) -> ()
        _listsEvery = \case
            Breakdown _ -> ()
            -- No row: 'State.Category.Flow.Par' draws it, not 'State.Category.Flow.Do'.
            FanOut _ -> ()
            Merge _ -> ()

    stepName = \case
        Breakdown fan -> breakdownName fan
        FanOut fan -> fanName fan
        Merge fan -> mergeName fan

    outcomes = \case
        Breakdown _ -> Continues (OutcomeName "done")
        FanOut fan -> Continues (fanEvent Leaves (fanName fan)).outcome
        Merge _ -> ExitsOr (OutcomeName "done") (OutcomeName "next_round")

    special = \case
        Breakdown _ -> Ordinary
        FanOut _ -> Ordinary
        Merge _ -> AwaitsMerge

    sameStep a b = case (a, b) of
        (Breakdown _, Breakdown _) -> Just Refl
        (Breakdown _, _) -> Nothing
        (FanOut _, FanOut _) -> Just Refl
        (FanOut _, _) -> Nothing
        (Merge _, Merge _) -> Just Refl
        (Merge _, _) -> Nothing

    pack = \case
        o@(BreakdownDone fan _) -> packed (Breakdown fan) o
        o@(FanDone fan) -> packed (FanOut fan) o
        o@(MergeDone fan _) -> packed (Merge fan) o
        o@(MergeNextRound fan) -> packed (Merge fan) o

    encodeOutcome = \case
        BreakdownDone _ tasks -> tasksData tasks
        FanDone _ -> mempty
        MergeDone _ url -> urlData url
        MergeNextRound _ -> mempty

    decoders =
        concat
            [ [ Decoder (Breakdown fan) (\obj -> BreakdownDone fan <$> (obj .: "tasks" >>= breakdownOf))
              , Decoder (FanOut fan) (const (pure (FanDone fan)))
              , Decoder (Merge fan) (fmap (MergeDone fan) . urlOf)
              , Decoder (Merge fan) (const (pure (MergeNextRound fan)))
              ]
            | fan <- [minBound .. maxBound]
            ]

deriving stock instance Show (Sing (s :: FanStep))
deriving stock instance Show (Outcome (s :: FanStep) l)
deriving stock instance Eq (Outcome (s :: FanStep) l)
