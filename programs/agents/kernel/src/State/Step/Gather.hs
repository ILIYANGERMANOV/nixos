{-# LANGUAGE TypeData #-}

{- | The actions of a task's gather, as the agent chooses them
('State.Category.Flow.Choice'): research a fact gap by a researcher in the
background, or interview the user; or, at a design discussion, ask the user
one design question.
-}
module State.Step.Gather (
    GatherStep,
    Sing (..),
    Outcome (..),
) where

import Data.Type.Equality ((:~:) (..))
import State.Category.Meter (Meter (..), Spend (..))
import State.Category.Step
import State.Category.Ty (Ty (..))

type data GatherStep = Research | Interview | Discuss

instance StepSet GatherStep where
    type Sig Research = '( 'Ctx, 'Nothing, 'Ctx)
    type Sig Interview = '( 'Ctx, 'Nothing, 'Ctx)
    type Sig Discuss = '( 'Ctx, 'Nothing, 'Ctx)
    type Drawn s = 'True

    data Sing s where
        Research :: Sing Research
        Interview :: Sing Interview
        Discuss :: Sing Discuss

    data Outcome s l where
        -- \| A researcher is spawned in the background.
        ResearchSpawned :: Outcome Research 'Opened
        -- \| A researcher handed back.
        ResearchHandedBack :: Outcome Research 'Closed

    layerSteps = [SomeStep Research, SomeStep Interview, SomeStep Discuss]
      where
        _listsEvery :: Sing (s :: GatherStep) -> ()
        _listsEvery = \case
            Research -> ()
            Interview -> ()
            Discuss -> ()

    stepName =
        StateName . \case
            Research -> "research"
            Interview -> "interview"
            Discuss -> "discuss"

    outcomes = \case
        Research -> OpensChildren
        Interview -> AsksOnly
        Discuss -> AsksOnly

    special = \case
        Research -> Ordinary
        Interview -> Ordinary
        Discuss -> Ordinary

    sameStep a b = case (a, b) of
        (Research, Research) -> Just Refl
        (Research, _) -> Nothing
        (Interview, Interview) -> Just Refl
        (Interview, _) -> Nothing
        (Discuss, Discuss) -> Just Refl
        (Discuss, _) -> Nothing

    pack = \case
        o@ResearchSpawned -> packed Research o
        o@ResearchHandedBack -> packed Research o

    encodeOutcome = \case
        ResearchSpawned -> mempty
        ResearchHandedBack -> mempty

    decoders =
        [ Decoder Research (const (pure ResearchSpawned))
        , Decoder Research (const (pure ResearchHandedBack))
        ]

deriving stock instance Show (Sing (s :: GatherStep))
deriving stock instance Show (Outcome (s :: GatherStep) l)
deriving stock instance Eq (Outcome (s :: GatherStep) l)

{- | Each researcher spawned; each must hand back before the gather ends.
Researchers are alike, so the run counts them: a spawn names none, and a
hand-back closes any one open.
-}
instance Meter Research where
    type Owes Research = 'True
    meterName Research = "Researchers"
    spends Research = \case
        Ends _ ResearchSpawned -> 1
        Ends _ ResearchHandedBack -> 0
        Asks -> 0

-- | Each question asked at the gather.
instance Meter Interview where
    meterName Interview = "Interview questions"
    spends Interview = \case
        Ends _ o -> case o of {}
        Asks -> 1

-- | Each design question asked at a discussion.
instance Meter Discuss where
    meterName Discuss = "Discussion questions"
    spends Discuss = \case
        Ends _ o -> case o of {}
        Asks -> 1
