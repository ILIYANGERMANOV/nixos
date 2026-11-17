{-# LANGUAGE TypeData #-}
{-# LANGUAGE UndecidableInstances #-}

{- | The 10x's steps around a fan-out: break the plan into tasks, then,
after its 'State.Flow.Library.par' of engineers, merge the PRs into one, or
end the round for the next. Each names its fan-out, so a run's fan-outs keep
their own tasks and children.
-}
module State.Step.Fan (
    FanStep,
    Sing (..),
    Outcome (..),
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
import State.Category.Flow (Name, nameText, namedState)
import State.Category.Meter (Meter (..), Spend (..))
import State.Category.Step
import State.Category.Ty (TyOf (..))
import State.Step.Artifact (Tasks, Url, breakdownOf, tasksData, urlData, urlOf)

type data FanStep = Breakdown | Merge

instance StepSet FanStep where
    type Sig Breakdown = '( 'Plan, 'Nothing, 'List 'Ctx)
    type Sig Merge = '( 'List 'PR, 'Just 'PR, 'Ctx)

    data Sing s where
        Breakdown :: Name -> Sing Breakdown
        Merge :: Name -> Sing Merge

    data Outcome s l where
        BreakdownDone :: Name -> Tasks -> Outcome Breakdown 'Continued
        -- \| The one PR the merge left: the run ends.
        MergeDone :: Name -> Url -> Outcome Merge 'Exited
        -- \| The round ends with its PRs merged, parked or kept: the next one starts at gathering.
        MergeNextRound :: Name -> Outcome Merge 'Continued

    layerSteps = concat [[SomeStep (Breakdown fan), SomeStep (Merge fan)] | fan <- fanOuts]
      where
        _listsEvery :: Sing (s :: FanStep) -> ()
        _listsEvery = \case
            Breakdown _ -> ()
            Merge _ -> ()

    stepName = \case
        Breakdown fan -> breakdownName fan
        Merge fan -> mergeName fan

    outcomes = \case
        Breakdown _ -> Continues (OutcomeName "done")
        Merge _ -> ExitsOr (OutcomeName "done") (OutcomeName "next_round")

    special = \case
        Breakdown _ -> Ordinary
        Merge _ -> AwaitsMerge

    sameStep a b = case (a, b) of
        (Breakdown _, Breakdown _) -> Just Refl
        (Breakdown _, _) -> Nothing
        (Merge _, Merge _) -> Just Refl
        (Merge _, _) -> Nothing

    pack = \case
        o@(BreakdownDone fan _) -> packed (Breakdown fan) o
        o@(MergeDone fan _) -> packed (Merge fan) o
        o@(MergeNextRound fan) -> packed (Merge fan) o

    encodeOutcome = \case
        BreakdownDone _ tasks -> tasksData tasks
        MergeDone _ url -> urlData url
        MergeNextRound _ -> mempty

    decoders =
        concat
            [ [ Decoder (Breakdown fan) (\obj -> BreakdownDone fan <$> (obj .: "tasks" >>= breakdownOf))
              , Decoder (Merge fan) (fmap (MergeDone fan) . urlOf)
              , Decoder (Merge fan) (const (pure (MergeNextRound fan)))
              ]
            | fan <- fanOuts
            ]

deriving stock instance Show (Sing (s :: FanStep))
deriving stock instance Show (Outcome (s :: FanStep) l)
deriving stock instance Eq (Outcome (s :: FanStep) l)

-- | The 10x's own fan-out: the engineers, one per task.
engineers :: Name
engineers = "engineers"

{- | Every fan-out a run may hold, so the log's decoders know each one's
events. Its order is the one the step table and the generators list.
-}
fanOuts :: [Name]
fanOuts = [engineers]

-- | The state of the fan-out's breakdown, before its 'State.Flow.Library.par'.
breakdownName :: Name -> StateName
breakdownName = fanStepName "breakdown"

-- | The state of the fan-out's merge, after its 'State.Flow.Library.par'.
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

-- | The fan-out whose state this is: its breakdown, its await or its merge.
fanOf :: StateName -> Maybe Name
fanOf name = find (\fan -> name `elem` [breakdownName fan, namedState fan, mergeName fan]) fanOuts

-- | The fan-out whose 'State.Category.Flow.Await' state, named by its group, this is.
fanNamed :: StateName -> Maybe Name
fanNamed name = find ((== name) . namedState) fanOuts

-- | Each round that leaves its PRs open: another round of the fan-out.
instance Meter Merge where
    meterName (Merge _) = "Rounds"
    spends (Merge _) = \case
        Ends _ (MergeNextRound _) -> 1
        Ends _ (MergeDone _ _) -> 0
        Asks -> 0
