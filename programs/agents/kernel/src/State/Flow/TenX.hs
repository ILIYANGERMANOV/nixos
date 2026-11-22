{- | The 10x flow of #351: agree on a plan, break it into tasks, run an
engineer per task, and merge their PRs into one. A round that leaves its PRs
open loops back to agree on the next round's plan, in the same run.
-}
module State.Flow.TenX (tenX, TenXS) where

import State.Category.Effect (Eff (PickE), Handler (PickHandler))
import State.Category.Flow (AgentRole (..), CapTarget (..), Flow (..), Group (..), Shape (..))
import State.Category.Meter (AtCap (..))
import State.Category.Ty (TyOf (..))
import State.Flow.Engineer (EngineerS, engineer)
import State.Flow.Library (AgreeS, ParallelS, agree, parallel, upTo)
import State.FlowName (FlowName (EngineerFlow), flowText)
import State.Step.Fan (FanStep (Breakdown, Merge), Sing (Breakdown, Merge), engineers)
import State.Step.Fuel (FuelStep (Fuel), Sing (Fuel))

-- | Each @next_round@ spends a round, so a stuck loop ends: 10 rounds are generous for one PR.
tenX :: Flow (HandleS PickE TenXS) 'Ctx 'Nothing 'PR
tenX = Handle PickHandler (Do Fuel :> Loop "round" (agree :> Do (Breakdown engineers) :> parallel (Group engineers (AgentRole (flowText EngineerFlow))) engineer :> upTo 9 Stop (Step (Merge engineers))))

type TenXS = DoS Fuel :>> LoopS (AgreeS :>> DoS Breakdown :>> ParallelS (HandleS PickE EngineerS) :>> CappedS (DoS Merge))
