{- | The architect flow: from an idea to a confirmed design ticket, changing
no code. Research opens the ticket as a work in progress; each design round
discusses, writes the design into the ticket and asks the user to confirm
it; an adjusted design discusses again, up to three rounds before the user
is asked whether to go on.
-}
module State.Flow.Architect (architect) where

import State.Category.Flow (Flow (..))
import State.Category.Fuel (always)
import State.Category.Meter (AtCap (..), Limit (..))
import State.Category.Ty (TyOf (..))
import State.Flow.Library (discuss, research)
import State.Step.Ticket (Sing (..))

architect :: Flow 'Ctx 'Nothing 'Ticket
architect =
    research
        :> Do OpenTicket
        :> Loop "design" (discuss :> Do UpdateTicket :> Capped (always (UpTo 3)) Extend ConfirmDesign)
        :> Do FinalizeTicket
