{- | The architect flow: from an idea to a confirmed design ticket, changing
no code. Research, then the problem talked through with the user until they
say it is understood; more research reopens it. Then design rounds, each
discussed and confirmed with the user; an adjusted design discusses again.
Only the confirmed design is written into a ticket, once. Each loop goes up
to three rounds before the user is asked whether to go on.
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
            :> Loop "understanding" (research :> Capped (always (UpTo 3)) Extend (Step Problem))
            :> Loop "design" (discuss :> Capped (always (UpTo 3)) Extend (Step ConfirmDesign))

type ArchitectS =
    DoS Fuel
        :>> LoopS (ResearchS :>> CappedS (DoS Problem))
        :>> LoopS (DiscussS :>> CappedS (DoS ConfirmDesign))
