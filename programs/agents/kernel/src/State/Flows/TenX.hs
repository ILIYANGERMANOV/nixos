{- | The 10x flow of #351: agree on a plan, break it into tasks, run an
engineer per task, and merge their PRs into one.
-}
module State.Flows.TenX (tenX) where

import State.Cap (Step (..), Ty (..))
import State.Flow (FanId (..), Flow (..))
import State.Flows.Blocks (agree)
import State.Flows.Engineer (engineer)

tenX :: Flow 'Ctx 'Nothing 'PR
tenX = agree :> Do Breakdown :> Par FEngineers engineer :> Do Merge
