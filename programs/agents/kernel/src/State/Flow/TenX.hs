{- | The 10x flow of #351: agree on a plan, break it into tasks, run an
engineer per task, and merge their PRs into one. A round that leaves its PRs
open loops back to agree on the next round's plan, in the same run.
-}
module State.Flow.TenX (tenX) where

import State.Block (agree)
import State.Category.Flow (FanId (..), Flow (..), LoopId (..), OnEmpty (..))
import State.Category.Ty (Ty (..))
import State.Flow.Engineer (engineer)
import State.Step.Fan (Sing (Breakdown, Merge))

tenX :: Flow 'Ctx 'Nothing 'PR
tenX = Loop LRound StopOut (agree :> Do (Breakdown FEngineers) :> Par FEngineers engineer :> Do (Merge FEngineers))
