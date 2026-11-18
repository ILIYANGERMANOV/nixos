{- | The 10x flow of #351: agree on a plan, break it into tasks, run an
engineer per task, and merge their PRs into one. A round that leaves its PRs
open loops back to agree on the next round's plan, in the same run.
-}
module State.Flow.TenX (tenX) where

import State.Category.Flow (AgentRole (..), CapTarget (..), Flow (..), Group (..))
import State.Category.Fuel (always)
import State.Category.Meter (AtCap (..), Limit (..))
import State.Category.Ty (TyOf (..))
import State.Flow.Engineer (engineer)
import State.Flow.Library (agree, par)
import State.FlowName (FlowName (EngineerFlow), flowText)
import State.Step.Fan (Sing (Breakdown, Merge), engineers)
import State.Step.Fuel (Sing (Fuel))

-- | Each @next_round@ spends a round, so a stuck loop ends: 10 rounds are generous for one PR.
tenX :: Flow 'Ctx 'Nothing 'PR
tenX = Do Fuel :> Loop "round" (agree :> Do (Breakdown engineers) :> par (Group engineers (AgentRole (flowText EngineerFlow))) engineer :> Capped (always (UpTo 9)) Stop (Step (Merge engineers)))
