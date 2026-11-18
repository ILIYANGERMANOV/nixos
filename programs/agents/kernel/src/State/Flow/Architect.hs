{- | The architect flow: from an idea to a confirmed design ticket, changing
no code. Research, then the problem talked through with the user until they
say it is understood; more research reopens it. Then design rounds, each
discussed and confirmed with the user; an adjusted design discusses again.
Only the confirmed design is written into a ticket, once. Each loop goes up
to three rounds before the user is asked whether to go on.
-}
module State.Flow.Architect (architect) where

import State.Category.Flow (CapTarget (..), Flow (..))
import State.Category.Fuel (always)
import State.Category.Meter (AtCap (..), Limit (..))
import State.Category.Ty (TyOf (..))
import State.Flow.Library (discuss, research)
import State.Step.Fuel (Sing (Fuel))
import State.Step.Ticket (Sing (..))

architect :: Flow 'Ctx 'Nothing 'Ticket
architect =
    Do Fuel
        :> Loop "understanding" (research :> Capped (always (UpTo 3)) Extend (Step Problem))
        :> Loop "design" (discuss :> Capped (always (UpTo 3)) Extend (Step ConfirmDesign))
