{- | The 10x flow of #351: agree on a plan, break it into tasks, run an
engineer per task, and merge their PRs into one. A round that leaves its PRs
open loops back to agree on the next round's plan, in the same run.
-}
module State.Flow.TenX (tenX, TenXS) where

import State.Category.Flow (AgentRole (..), CapTarget (..), Flow (..), Group (..), Shape (..))
import State.Category.Fuel (always)
import State.Category.Meter (AtCap (..), Limit (..))
import State.Category.Ty (TyOf (..))
import State.Flow.Engineer (EngineerS, engineer)
import State.Flow.Library (AgreeS, Handled, ParS, agree, handled, par)
import State.FlowName (FlowName (EngineerFlow), flowText)
import State.Step.Fan (FanStep (Breakdown, Merge), Sing (Breakdown, Merge), engineers)
import State.Step.Fuel (FuelStep (Fuel), Sing (Fuel))

-- | Each @next_round@ spends a round, so a stuck loop ends: 10 rounds are generous for one PR.
tenX :: Flow (Handled TenXS) 'Ctx 'Nothing 'PR
tenX = handled (Do Fuel :> Loop "round" (agree :> Do (Breakdown engineers) :> par (Group engineers (AgentRole (flowText EngineerFlow))) engineer :> Capped (always (UpTo 9)) Stop (Step (Merge engineers))))

type TenXS = DoS Fuel :>> LoopS (AgreeS :>> DoS Breakdown :>> ParS (Handled EngineerS) :>> CappedS (DoS Merge))
