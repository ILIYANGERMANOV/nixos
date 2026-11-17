{-# LANGUAGE TypeData #-}
{-# LANGUAGE UndecidableInstances #-}

{- | The state a 'State.Category.Flow.Choice' draws, named by its choice: a
step of this layer for its one outcome, @enough@, never one
'State.Category.Flow.Do' draws. Its actions' events are their own steps'.
A 'State.Category.Flow.Route''s hub is a step of this layer per branch,
each for its one outcome, the branch. No flow draws either, so no log reads one.
-}
module State.Step.Choice (
    ChoiceStep,
    Sing (..),
    Outcome (..),
) where

import Data.Type.Equality ((:~:) (..))
import GHC.TypeError (ErrorMessage (..), TypeError)
import State.Category.Flow (Name, enoughOutcome, namedState)
import State.Category.Step
import State.Category.Ty (TyOf (..))

type data ChoiceStep = Hub | Fork

type DrawnHub :: ChoiceStep -> Bool
type family DrawnHub s where
    DrawnHub Hub = TypeError ('Text "A choice's state is drawn by Choice, not Do")
    DrawnHub Fork = TypeError ('Text "A route's state is drawn by Route, not Do")

instance StepSet ChoiceStep where
    type Sig Hub = '( 'Ctx, 'Nothing, 'Ctx)
    type Sig Fork = '( 'Ctx, 'Nothing, 'Ctx)
    type Drawn s = DrawnHub s

    data Sing s where
        Hub :: Name -> Sing Hub
        -- \| A route's hub, by one of its branches.
        Pick :: Name -> OutcomeName -> Sing Fork

    data Outcome s l where
        -- \| Nothing is open: the run leaves the choice.
        Enough :: Name -> Outcome Hub 'Continued
        -- \| The route goes on into this branch.
        Picked :: Name -> OutcomeName -> Outcome Fork 'Continued

    -- No row: 'State.Category.Flow.Choice' and 'State.Category.Flow.Route' draw them, not 'State.Category.Flow.Do'.
    layerSteps = []

    stepName = \case
        Hub name -> namedState name
        Pick route _ -> namedState route

    outcomes = \case
        Hub _ -> Continues enoughOutcome
        Pick _ branch -> Continues branch

    special = \case
        Hub _ -> Ordinary
        Pick _ _ -> Ordinary

    sameStep a b = case (a, b) of
        (Hub _, Hub _) -> Just Refl
        (Hub _, Pick _ _) -> Nothing
        (Pick _ _, Pick _ _) -> Just Refl
        (Pick _ _, Hub _) -> Nothing

    pack = \case
        o@(Enough name) -> packed (Hub name) o
        o@(Picked route branch) -> packed (Pick route branch) o

    encodeOutcome = \case
        Enough _ -> mempty
        Picked _ _ -> mempty

    -- None: no flow draws a choice or a route, so no log reads one.
    decoders = []

deriving stock instance Show (Sing (s :: ChoiceStep))
deriving stock instance Show (Outcome (s :: ChoiceStep) l)
deriving stock instance Eq (Outcome (s :: ChoiceStep) l)
