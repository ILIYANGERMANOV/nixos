{-# LANGUAGE TypeData #-}
{-# LANGUAGE UndecidableInstances #-}

{- | The state a 'State.Category.Flow.Choice' draws, named by its choice: a
step of this layer for its one outcome, @enough@, never one
'State.Category.Flow.Do' draws. Its actions' events are their own steps'.
-}
module State.Step.Choice (
    ChoiceStep,
    Sing (..),
    Outcome (..),
    gathering,
    choices,
    choiceNamed,
) where

import Data.List (find)
import Data.Type.Equality ((:~:) (..))
import GHC.TypeError (ErrorMessage (..), TypeError)
import State.Category.Flow (Name, choiceName, enoughOutcome)
import State.Category.Step
import State.Category.Ty (Ty (..))

type data ChoiceStep = Hub

type DrawnHub :: ChoiceStep -> Bool
type family DrawnHub s where
    DrawnHub Hub = TypeError ('Text "A choice's state is drawn by Choice, not Do")

instance StepSet ChoiceStep where
    type Sig Hub = '( 'Ctx, 'Nothing, 'Ctx)
    type Drawn s = DrawnHub s

    data Sing s where
        Hub :: Name -> Sing Hub

    data Outcome s l where
        -- \| Nothing is open: the run leaves the choice.
        Enough :: Name -> Outcome Hub 'Continued

    -- No row: 'State.Category.Flow.Choice' draws it, not 'State.Category.Flow.Do'.
    layerSteps = []

    stepName (Hub name) = choiceName name

    outcomes (Hub _) = Continues enoughOutcome

    special (Hub _) = Ordinary

    sameStep (Hub _) (Hub _) = Just Refl

    pack = \case
        o@(Enough name) -> packed (Hub name) o

    encodeOutcome (Enough _) = mempty

    decoders = [Decoder (Hub name) (const (pure (Enough name))) | name <- choices]

deriving stock instance Show (Sing (s :: ChoiceStep))
deriving stock instance Show (Outcome (s :: ChoiceStep) l)
deriving stock instance Eq (Outcome (s :: ChoiceStep) l)

-- | The engineer's and the 10x's gather: research and interview, as the agent chooses.
gathering :: Name
gathering = "gather"

-- | Every choice a run may hold, so the log's decoders know each one's @enough@.
choices :: [Name]
choices = [gathering]

-- | The choice whose state this is.
choiceNamed :: StateName -> Maybe Name
choiceNamed name = find ((== name) . choiceName) choices
