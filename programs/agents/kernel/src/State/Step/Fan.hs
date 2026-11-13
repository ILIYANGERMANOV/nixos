{-# LANGUAGE TypeData #-}
{-# LANGUAGE UndecidableInstances #-}

{- | The 10x's steps around its fan-out: break the plan into tasks, leave
the fan-out once every task is settled, merge the PRs into one.
-}
module State.Step.Fan (
    FanStep,
    Sing (..),
    Outcome (..),
) where

import Data.Aeson ((.:), (.=))
import Data.Type.Equality ((:~:) (..))
import GHC.TypeError (ErrorMessage (..), TypeError)
import State.Category.Flow (FanEvent (Leaves), FanId, fanEvent, fanName)
import State.Category.Step
import State.Category.Ty (Ty (..))
import State.Step.Artifact (Tasks, Url, breakdownOf, tasksData, urlOf, urlText)

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
    type Sig Merge = '( 'List 'PR, 'Nothing, 'PR)
    type Drawn s = DrawnFan s

    data Sing s where
        Breakdown :: Sing Breakdown
        FanOut :: FanId -> Sing FanOut
        Merge :: Sing Merge

    data Outcome s l where
        BreakdownDone :: Tasks -> Outcome Breakdown 'Continued
        -- \| Every task of the fan-out is settled ("State.Run.Fan").
        FanDone :: FanId -> Outcome FanOut 'Continued
        -- \| The one PR the merge left.
        MergeDone :: Url -> Outcome Merge 'Continued

    layerSteps = [SomeStep Breakdown, SomeStep Merge]
      where
        _listsEvery :: Sing (s :: FanStep) -> ()
        _listsEvery = \case
            Breakdown -> ()
            -- No row: 'State.Category.Flow.Par' draws it, not 'State.Category.Flow.Do'.
            FanOut _ -> ()
            Merge -> ()

    stepName = \case
        Breakdown -> StateName "breakdown"
        FanOut fan -> fanName fan
        Merge -> StateName "merge"

    outcomes = \case
        Breakdown -> Continues (OutcomeName "done")
        FanOut fan -> Continues (fanEvent Leaves (fanName fan)).outcome
        Merge -> Continues (OutcomeName "done")

    special = \case
        Breakdown -> Ordinary
        FanOut _ -> Ordinary
        Merge -> AwaitsMerge

    sameStep a b = case (a, b) of
        (Breakdown, Breakdown) -> Just Refl
        (FanOut _, FanOut _) -> Just Refl
        (Merge, Merge) -> Just Refl
        _ -> Nothing

    pack = \case
        o@(BreakdownDone _) -> packed Breakdown o
        o@(FanDone fan) -> packed (FanOut fan) o
        o@(MergeDone _) -> packed Merge o

    encodeOutcome = \case
        BreakdownDone tasks -> tasksData tasks
        FanDone _ -> mempty
        MergeDone url -> "url" .= urlText url

    decoders =
        [Decoder Breakdown (\obj -> BreakdownDone <$> (obj .: "tasks" >>= breakdownOf))]
            <> [Decoder (FanOut fan) (const (pure (FanDone fan))) | fan <- [minBound .. maxBound]]
            <> [Decoder Merge (fmap MergeDone . urlOf)]

deriving stock instance Show (Sing (s :: FanStep))
deriving stock instance Show (Outcome (s :: FanStep) l)
deriving stock instance Eq (Outcome (s :: FanStep) l)
