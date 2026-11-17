-- | The engineer flow of #351: from a task's context, at the Fuel given it, to a ready PR.
module State.Flow.Engineer (engineer) where

import State.Category.Flow (Flow (..))
import State.Category.Ty (TyOf (..))
import State.Flow.Library (agree, build, describe, reviewed, ship)
import State.Step.Fuel (Sing (Fuel))

engineer :: Flow 'Ctx 'Nothing 'PR
engineer = Do Fuel :> agree :> build :> reviewed :> describe :> ship
