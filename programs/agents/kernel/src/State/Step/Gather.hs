{-# LANGUAGE TypeData #-}

{- | The actions of a task's gather, as the agent picks them
('State.Flow.Library.choiceLoop'): research a fact gap by a researcher in the
background, or interview the user; or, at a design discussion, ask the user
design questions. The researchers' notes merge into the context once every
one handed back.
-}
module State.Step.Gather (
    GatherStep,
    Sing (..),
    Outcome (..),
) where

import Data.Type.Equality ((:~:) (..))
import State.Category.Meter (Meter (..), Spend (..))
import State.Category.Step
import State.Category.Ty (TyOf (..))

type data GatherStep = Research | Interview | Discuss | Notes

instance StepSet GatherStep where
    type Sig Research = '( 'Ctx, 'Nothing, 'Ctx)
    type Sig Interview = '( 'Ctx, 'Nothing, 'Ctx)
    type Sig Discuss = '( 'Ctx, 'Nothing, 'Ctx)
    type Sig Notes = '( 'List 'Ctx, 'Nothing, 'Ctx)

    data Sing s where
        Research :: Sing Research
        Interview :: Sing Interview
        Discuss :: Sing Discuss
        Notes :: Sing Notes

    data Outcome s l where
        -- \| A researcher is spawned in the background.
        ResearchSpawned :: Outcome Research 'Opened
        -- \| A researcher handed back.
        ResearchHandedBack :: Outcome Research 'Closed
        -- \| The questions of this round are asked: back to the pick.
        InterviewAsked :: Outcome Interview 'Continued
        DiscussAsked :: Outcome Discuss 'Continued
        -- \| The researchers' hand-backs are merged into the notes.
        NotesDone :: Outcome Notes 'Continued

    layerSteps = [SomeStep Research, SomeStep Interview, SomeStep Discuss, SomeStep Notes]
      where
        _listsEvery :: Sing (s :: GatherStep) -> ()
        _listsEvery = \case
            Research -> ()
            Interview -> ()
            Discuss -> ()
            Notes -> ()

    stepName =
        StateName . \case
            Research -> "research"
            Interview -> "interview"
            Discuss -> "discuss"
            Notes -> "notes"

    outcomes = \case
        Research -> OpensChildren
        Interview -> Continues (OutcomeName "asked")
        Discuss -> Continues (OutcomeName "asked")
        Notes -> Continues (OutcomeName "done")

    special = \case
        Research -> Ordinary
        Interview -> Ordinary
        Discuss -> Ordinary
        Notes -> Ordinary

    sameStep a b = case (a, b) of
        (Research, Research) -> Just Refl
        (Research, _) -> Nothing
        (Interview, Interview) -> Just Refl
        (Interview, _) -> Nothing
        (Discuss, Discuss) -> Just Refl
        (Discuss, _) -> Nothing
        (Notes, Notes) -> Just Refl
        (Notes, _) -> Nothing

    pack = \case
        o@ResearchSpawned -> packed Research o
        o@ResearchHandedBack -> packed Research o
        o@InterviewAsked -> packed Interview o
        o@DiscussAsked -> packed Discuss o
        o@NotesDone -> packed Notes o

    encodeOutcome = \case
        ResearchSpawned -> mempty
        ResearchHandedBack -> mempty
        InterviewAsked -> mempty
        DiscussAsked -> mempty
        NotesDone -> mempty

    decoders =
        [ Decoder Research (const (pure ResearchSpawned))
        , Decoder Research (const (pure ResearchHandedBack))
        , Decoder Interview (const (pure InterviewAsked))
        , Decoder Discuss (const (pure DiscussAsked))
        , Decoder Notes (const (pure NotesDone))
        ]

deriving stock instance Show (Sing (s :: GatherStep))
deriving stock instance Show (Outcome (s :: GatherStep) l)
deriving stock instance Eq (Outcome (s :: GatherStep) l)

{- | Each researcher spawned, by the 'State.Category.Flow.Fork' of this
step; each must hand back before the gather's 'State.Category.Flow.Await'
goes on. Researchers are alike, so the run counts them: a spawn names none,
and a hand-back closes any one open.
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
        Ends _ InterviewAsked -> 0
        Asks -> 1

-- | Each design question asked at a discussion.
instance Meter Discuss where
    meterName Discuss = "Discussion questions"
    spends Discuss = \case
        Ends _ DiscussAsked -> 0
        Asks -> 1
