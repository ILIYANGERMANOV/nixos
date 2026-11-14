{-# LANGUAGE TypeData #-}

-- | The steps that gather a task's context: research it, then interview the user.
module State.Step.Gather (
    GatherStep,
    Sing (..),
    Outcome (..),
) where

import Data.Aeson ((.:), (.=))
import Data.Type.Equality ((:~:) (..))
import Numeric.Natural (Natural)
import State.Category.Step
import State.Category.Ty (Ty (..))

type data GatherStep = Research | Interview

instance StepSet GatherStep where
    type Sig Research = '( 'Ctx, 'Nothing, 'Ctx)
    type Sig Interview = '( 'Ctx, 'Just 'Ctx, 'Ctx)
    type Drawn s = 'True

    data Sing s where
        Research :: Sing Research
        Interview :: Sing Interview

    data Outcome s l where
        -- \| The number of researchers.
        ResearchDone :: Natural -> Outcome Research 'Continued
        ResearchSkipped :: Outcome Research 'Skipped
        InterviewEnough :: Outcome Interview 'Exited
        InterviewMore :: Outcome Interview 'Continued

    layerSteps = [SomeStep Research, SomeStep Interview]
      where
        _listsEvery :: Sing (s :: GatherStep) -> ()
        _listsEvery = \case
            Research -> ()
            Interview -> ()

    stepName =
        StateName . \case
            Research -> "research"
            Interview -> "interview"

    outcomes = \case
        Research -> Continues (OutcomeName "done")
        Interview -> ExitsOr (OutcomeName "enough") (OutcomeName "more")

    special = \case
        Research -> Ordinary
        Interview -> Ordinary

    sameStep a b = case (a, b) of
        (Research, Research) -> Just Refl
        (Research, _) -> Nothing
        (Interview, Interview) -> Just Refl
        (Interview, _) -> Nothing

    pack = \case
        o@(ResearchDone _) -> packed Research o
        o@ResearchSkipped -> packed Research o
        o@InterviewEnough -> packed Interview o
        o@InterviewMore -> packed Interview o

    encodeOutcome = \case
        ResearchDone n -> "n" .= n
        ResearchSkipped -> mempty
        InterviewEnough -> mempty
        InterviewMore -> mempty

    decoders =
        [ Decoder Research (\obj -> ResearchDone <$> obj .: "n")
        , Decoder Research (const (pure ResearchSkipped))
        , Decoder Interview (const (pure InterviewEnough))
        , Decoder Interview (const (pure InterviewMore))
        ]

deriving stock instance Show (Sing (s :: GatherStep))
deriving stock instance Show (Outcome (s :: GatherStep) l)
deriving stock instance Eq (Outcome (s :: GatherStep) l)
