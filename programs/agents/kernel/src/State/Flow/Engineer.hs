-- | The engineer flow of #351: from a task's context to a ready PR.
module State.Flow.Engineer (engineer) where

import State.Category.Flow (Flow (..))
import State.Category.Ty (TyOf (..))
import State.Flow.Library (agree, build, describe, reviewed, ship)

engineer :: Flow 'Ctx 'Nothing 'PR
engineer = agree :> build :> reviewed :> describe :> ship
