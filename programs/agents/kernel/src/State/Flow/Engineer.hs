-- | The engineer flow of #351: from a task's context, at the Fuel given it, to a ready PR.
module State.Flow.Engineer (engineer, EngineerS) where

import State.Category.Effect (Eff (PickE), Handler (PickHandler))
import State.Category.Flow (Flow (..), Shape (..))
import State.Category.Ty (TyOf (..))
import State.Flow.Library (AgreeS, BuildS, DescribeS, ReviewS, ShipS, agree, build, describe, review, ship)
import State.Step.Fuel (FuelStep (Fuel), Sing (Fuel))

engineer :: Flow (HandleS PickE EngineerS) 'Ctx 'Nothing 'PR
engineer = Handle PickHandler (Do Fuel :> agree :> build :> review :> describe :> ship)

type EngineerS = DoS Fuel :>> AgreeS :>> BuildS :>> ReviewS :>> DescribeS :>> ShipS
