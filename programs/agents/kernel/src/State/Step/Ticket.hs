{-# LANGUAGE TypeData #-}

{- | The ticket an architect writes, or edits, at any point of its
discussion, any number of times. The lead runs it and changes no code.
-}
module State.Step.Ticket (
    TicketStep (..),
    Sing (..),
    Outcome (..),
) where

import Data.Type.Equality ((:~:) (..))
import State.Category.Step
import State.Category.Ty (TyOf (..))
import State.Step.Artifact (Url, urlData, urlOf)

type data TicketStep = WriteTicket

instance StepSet TicketStep where
    type Raises s = '[]

    type Sig WriteTicket = '( 'Ctx, 'Nothing, 'Ctx)

    data Sing s where
        WriteTicket :: Sing WriteTicket

    data Outcome s l where
        -- \| The ticket's url, written or edited: the latest is what the run names at its end.
        TicketWritten :: Url -> Outcome WriteTicket 'Continued

    layerSteps = [SomeStep WriteTicket]
      where
        _listsEvery :: Sing (s :: TicketStep) -> ()
        _listsEvery = \case
            WriteTicket -> ()

    stepName =
        StateName . \case
            WriteTicket -> "ticket"

    outcomes = \case
        WriteTicket -> Continues (OutcomeName "written")

    special = \case
        WriteTicket -> Ordinary

    sameStep a b = case (a, b) of
        (WriteTicket, WriteTicket) -> Just Refl

    pack = \case
        o@(TicketWritten _) -> packed WriteTicket o

    encodeOutcome = \case
        TicketWritten url -> urlData url

    decoders =
        [ Decoder WriteTicket (fmap TicketWritten . urlOf)
        ]

deriving stock instance Show (Sing (s :: TicketStep))
deriving stock instance Show (Outcome (s :: TicketStep) l)
deriving stock instance Eq (Outcome (s :: TicketStep) l)
