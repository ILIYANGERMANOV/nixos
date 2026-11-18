{-# LANGUAGE TypeData #-}

{- | The steps that settle a problem and its design with the user, then write
the design into a ticket once. The lead runs each, in the issue tracker, and
changes no code.
-}
module State.Step.Ticket (
    TicketStep,
    Sing (..),
    Outcome (..),
) where

import Data.Type.Equality ((:~:) (..))
import State.Category.Meter (Meter (..), Spend (..))
import State.Category.Step
import State.Category.Ty (TyOf (..))
import State.Step.Artifact (Url, urlData, urlOf)

type data TicketStep = Problem | ConfirmDesign

instance StepSet TicketStep where
    type Sig Problem = '( 'Ctx, 'Just 'Ctx, 'Ctx)
    type Sig ConfirmDesign = '( 'Ctx, 'Just 'Ticket, 'Ctx)

    data Sing s where
        Problem :: Sing Problem
        ConfirmDesign :: Sing ConfirmDesign

    data Outcome s l where
        ProblemUnderstood :: Outcome Problem 'Exited
        ProblemMore :: Outcome Problem 'Continued
        -- \| The ticket's url, written once the user confirmed the design: the
        -- run hands it back at its end.
        ConfirmDesignConfirmed :: Url -> Outcome ConfirmDesign 'Exited
        ConfirmDesignAdjusted :: Outcome ConfirmDesign 'Continued

    layerSteps = [SomeStep Problem, SomeStep ConfirmDesign]
      where
        _listsEvery :: Sing (s :: TicketStep) -> ()
        _listsEvery = \case
            Problem -> ()
            ConfirmDesign -> ()

    stepName =
        StateName . \case
            Problem -> "problem"
            ConfirmDesign -> "confirm_design"

    outcomes = \case
        Problem -> ExitsOr (OutcomeName "understood") (OutcomeName "more")
        ConfirmDesign -> ExitsOr (OutcomeName "confirmed") (OutcomeName "adjusted")

    special = \case
        Problem -> AsksConfirm OnUserWord "the problem"
        ConfirmDesign -> AsksConfirm OnEntry "the design"

    sameStep a b = case (a, b) of
        (Problem, Problem) -> Just Refl
        (Problem, _) -> Nothing
        (ConfirmDesign, ConfirmDesign) -> Just Refl
        (ConfirmDesign, _) -> Nothing

    pack = \case
        o@ProblemUnderstood -> packed Problem o
        o@ProblemMore -> packed Problem o
        o@(ConfirmDesignConfirmed _) -> packed ConfirmDesign o
        o@ConfirmDesignAdjusted -> packed ConfirmDesign o

    encodeOutcome = \case
        ProblemUnderstood -> mempty
        ProblemMore -> mempty
        ConfirmDesignConfirmed url -> urlData url
        ConfirmDesignAdjusted -> mempty

    decoders =
        [ Decoder Problem (const (pure ProblemUnderstood))
        , Decoder Problem (const (pure ProblemMore))
        , Decoder ConfirmDesign (fmap ConfirmDesignConfirmed . urlOf)
        , Decoder ConfirmDesign (const (pure ConfirmDesignAdjusted))
        ]

deriving stock instance Show (Sing (s :: TicketStep))
deriving stock instance Show (Outcome (s :: TicketStep) l)
deriving stock instance Eq (Outcome (s :: TicketStep) l)

-- | Each round the problem needs more: more research and discussion.
instance Meter Problem where
    meterName Problem = "Problem rounds"
    spends Problem = \case
        Ends _ ProblemMore -> 1
        Ends _ ProblemUnderstood -> 0
        Asks -> 0

-- | Each adjusted design: another round of discussing it.
instance Meter ConfirmDesign where
    meterName ConfirmDesign = "Design rounds"
    spends ConfirmDesign = \case
        Ends _ ConfirmDesignAdjusted -> 1
        Ends _ (ConfirmDesignConfirmed _) -> 0
        Asks -> 0
