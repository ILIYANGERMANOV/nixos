{- | The architect flow: from an idea to a confirmed design ticket, changing
no code. Research opens the ticket as a work in progress; each design round
discusses, writes the design into the ticket and asks the user to confirm
it; an adjusted design discusses again, up to three rounds before the user
is asked whether to go on.
-}
module State.Flow.Architect (architect, ArchitectS) where

import State.Category.Flow (CapTarget (..), Flow (..), Shape (..))
import State.Category.Fuel (always)
import State.Category.Meter (AtCap (..), Limit (..))
import State.Category.Ty (TyOf (..))
import State.Flow.Library (DiscussS, Handled, ResearchS, discuss, handled, research)
import State.Step.Fuel (FuelStep (Fuel), Sing (Fuel))
import State.Step.Ticket (Sing (..), TicketStep (..))

architect :: Flow (Handled ArchitectS) 'Ctx 'Nothing 'Ticket
architect =
    handled $
        Do Fuel
            :> research
            :> Do OpenTicket
            :> Loop "design" (discuss :> Do UpdateTicket :> Capped (always (UpTo 3)) Extend (Step ConfirmDesign))
            :> Do FinalizeTicket

type ArchitectS =
    DoS Fuel
        :>> ResearchS
        :>> DoS OpenTicket
        :>> LoopS (DiscussS :>> DoS UpdateTicket :>> CappedS (DoS ConfirmDesign))
        :>> DoS FinalizeTicket
