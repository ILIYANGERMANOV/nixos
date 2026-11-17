{-# LANGUAGE TypeData #-}

{- | The steps that write a design into a ticket: open it as a work in
progress, write the design into it, confirm it with the user, finalize it.
The lead runs each, in the issue tracker, and changes no code.
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

type data TicketStep = OpenTicket | UpdateTicket | ConfirmDesign | FinalizeTicket

instance StepSet TicketStep where
    type Sig OpenTicket = '( 'Ctx, 'Nothing, 'Ctx)
    type Sig UpdateTicket = '( 'Ctx, 'Nothing, 'Ticket)
    type Sig ConfirmDesign = '( 'Ticket, 'Just 'Ticket, 'Ctx)
    type Sig FinalizeTicket = '( 'Ticket, 'Nothing, 'Ticket)

    data Sing s where
        OpenTicket :: Sing OpenTicket
        UpdateTicket :: Sing UpdateTicket
        ConfirmDesign :: Sing ConfirmDesign
        FinalizeTicket :: Sing FinalizeTicket

    data Outcome s l where
        -- \| The ticket's url: the run hands it back at its end.
        OpenTicketDone :: Url -> Outcome OpenTicket 'Continued
        UpdateTicketDone :: Outcome UpdateTicket 'Continued
        ConfirmDesignConfirmed :: Outcome ConfirmDesign 'Exited
        ConfirmDesignAdjusted :: Outcome ConfirmDesign 'Continued
        FinalizeTicketDone :: Outcome FinalizeTicket 'Continued

    layerSteps = [SomeStep OpenTicket, SomeStep UpdateTicket, SomeStep ConfirmDesign, SomeStep FinalizeTicket]
      where
        _listsEvery :: Sing (s :: TicketStep) -> ()
        _listsEvery = \case
            OpenTicket -> ()
            UpdateTicket -> ()
            ConfirmDesign -> ()
            FinalizeTicket -> ()

    stepName =
        StateName . \case
            OpenTicket -> "open_ticket"
            UpdateTicket -> "update_ticket"
            ConfirmDesign -> "confirm_design"
            FinalizeTicket -> "finalize_ticket"

    outcomes = \case
        OpenTicket -> Continues (OutcomeName "done")
        UpdateTicket -> Continues (OutcomeName "done")
        ConfirmDesign -> ExitsOr (OutcomeName "confirmed") (OutcomeName "adjusted")
        FinalizeTicket -> Continues (OutcomeName "done")

    special = \case
        OpenTicket -> Ordinary
        UpdateTicket -> Ordinary
        ConfirmDesign -> AsksConfirm "the design ticket"
        FinalizeTicket -> Ordinary

    sameStep a b = case (a, b) of
        (OpenTicket, OpenTicket) -> Just Refl
        (OpenTicket, _) -> Nothing
        (UpdateTicket, UpdateTicket) -> Just Refl
        (UpdateTicket, _) -> Nothing
        (ConfirmDesign, ConfirmDesign) -> Just Refl
        (ConfirmDesign, _) -> Nothing
        (FinalizeTicket, FinalizeTicket) -> Just Refl
        (FinalizeTicket, _) -> Nothing

    pack = \case
        o@(OpenTicketDone _) -> packed OpenTicket o
        o@UpdateTicketDone -> packed UpdateTicket o
        o@ConfirmDesignConfirmed -> packed ConfirmDesign o
        o@ConfirmDesignAdjusted -> packed ConfirmDesign o
        o@FinalizeTicketDone -> packed FinalizeTicket o

    encodeOutcome = \case
        OpenTicketDone url -> urlData url
        UpdateTicketDone -> mempty
        ConfirmDesignConfirmed -> mempty
        ConfirmDesignAdjusted -> mempty
        FinalizeTicketDone -> mempty

    decoders =
        [ Decoder OpenTicket (fmap OpenTicketDone . urlOf)
        , Decoder UpdateTicket (const (pure UpdateTicketDone))
        , Decoder ConfirmDesign (const (pure ConfirmDesignConfirmed))
        , Decoder ConfirmDesign (const (pure ConfirmDesignAdjusted))
        , Decoder FinalizeTicket (const (pure FinalizeTicketDone))
        ]

deriving stock instance Show (Sing (s :: TicketStep))
deriving stock instance Show (Outcome (s :: TicketStep) l)
deriving stock instance Eq (Outcome (s :: TicketStep) l)

-- | Each adjusted design: another round of discussing and writing it.
instance Meter ConfirmDesign where
    meterName ConfirmDesign = "Design rounds"
    spends ConfirmDesign = \case
        Ends _ ConfirmDesignAdjusted -> 1
        Ends _ ConfirmDesignConfirmed -> 0
        Asks -> 0
