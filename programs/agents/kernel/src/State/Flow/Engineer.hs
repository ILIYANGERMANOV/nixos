-- | The engineer flow of #351: from a task's context, at the Fuel given it, to a ready PR.
module State.Flow.Engineer (engineer, EngineerS) where

import State.Category.Flow (Flow (..), Shape (..))
import State.Category.Ty (TyOf (..))
import State.Flow.Library (AgreeS, BuildS, DescribeS, Handled, ReviewedS, ShipS, agree, build, describe, handled, reviewed, ship)
import State.Step.Fuel (FuelStep (Fuel), Sing (Fuel))

engineer :: Flow (Handled EngineerS) 'Ctx 'Nothing 'PR
engineer = handled (Do Fuel :> agree :> build :> reviewed :> describe :> ship)

type EngineerS = DoS Fuel :>> AgreeS :>> BuildS :>> ReviewedS :>> DescribeS :>> ShipS
