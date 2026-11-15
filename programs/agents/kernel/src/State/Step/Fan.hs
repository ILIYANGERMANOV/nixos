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
    researchers,
    engineers,
    fanOuts,
    breakdownName,
    mergeName,
    fanOf,
    fanNamed,
) where

import Data.Aeson ((.:))
import Data.List (find)
import Data.Text (Text)
import Data.Type.Equality ((:~:) (..))
import State.Category.Meter (Meter (..), Spend (..))
import GHC.TypeError (ErrorMessage (..), TypeError)
import State.Category.Flow (FanEvent (Leaves), Name, fanEvent, fanName, nameText)
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
        Breakdown :: Name -> Sing Breakdown
        FanOut :: Name -> Sing FanOut
        Merge :: Name -> Sing Merge

    data Outcome s l where
        BreakdownDone :: Name -> Tasks -> Outcome Breakdown 'Continued
        -- \| Every task of the fan-out is settled ("State.Run.Fan").
        FanDone :: Name -> Outcome FanOut 'Continued
        -- \| The one PR the merge left: the run ends.
        MergeDone :: Name -> Url -> Outcome Merge 'Exited
        -- \| The round ends with its PRs merged, parked or kept: the next one starts at gathering.
        MergeNextRound :: Name -> Outcome Merge 'Continued

    layerSteps = concat [[SomeStep (Breakdown fan), SomeStep (Merge fan)] | fan <- fanOuts]
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
            | fan <- fanOuts
            ]

deriving stock instance Show (Sing (s :: FanStep))
deriving stock instance Show (Outcome (s :: FanStep) l)
deriving stock instance Eq (Outcome (s :: FanStep) l)

-- | The 10x's own fan-outs: the researchers it may send, and the engineers.
researchers, engineers :: Name
researchers = "researchers"
engineers = "engineers"

{- | Every fan-out a run may hold, so the log's decoders know each one's
events. Its order is the one the step table and the generators list.
-}
fanOuts :: [Name]
fanOuts = [researchers, engineers]

-- | The state of the fan-out's breakdown, before its 'State.Category.Flow.Par'.
breakdownName :: Name -> StateName
breakdownName = fanStepName "breakdown"

-- | The state of the fan-out's merge, after its 'State.Category.Flow.Par'.
mergeName :: Name -> StateName
mergeName = fanStepName "merge"

{- | The engineers' breakdown and merge keep their bare names, @breakdown@
and @merge@, as the 10x skill names them; another fan-out's are prefixed with
its own name, as state names are unique.
-}
fanStepName :: Text -> Name -> StateName
fanStepName step fan
    | fan == engineers = StateName step
    | otherwise = StateName (nameText fan <> "_" <> step)

-- | The fan-out whose state this is: its breakdown, its own or its merge.
fanOf :: StateName -> Maybe Name
fanOf name = find (\fan -> name `elem` [breakdownName fan, fanName fan, mergeName fan]) fanOuts

-- | The fan-out whose own state, the one its 'State.Category.Flow.Par' draws, this is.
fanNamed :: StateName -> Maybe Name
fanNamed name = find ((== name) . fanName) fanOuts

-- | Each round that leaves its PRs open: another round of the fan-out.
instance Meter Merge where
    meterName (Merge _) = "Rounds"
    spends (Merge _) = \case
        Ends _ (MergeNextRound _) -> 1
        Ends _ (MergeDone _ _) -> 0
        Asks -> 0
