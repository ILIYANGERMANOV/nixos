-- | The engineer flow of #351: from a task's context to a ready PR.
module State.Flows.Engineer (engineer) where

import State.Cap (Ty (..))
import State.Flow (Flow (..))
import State.Flows.Blocks (agree, build, describe, review, ship)

engineer :: Flow 'Ctx 'Nothing 'PR
engineer = agree :> build :> review :> describe :> ship
