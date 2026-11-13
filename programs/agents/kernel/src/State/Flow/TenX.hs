{- | The 10x flow of #351: agree on a plan, break it into tasks, run an
engineer per task, and merge their PRs into one.
-}
module State.Flow.TenX (tenX) where

import State.Block (agree)
import State.Category.Flow (FanId (..), Flow (..))
import State.Category.Ty (Ty (..))
import State.Flow.Engineer (engineer)
import State.Step.Fan (Sing (Breakdown, Merge))

tenX :: Flow 'Ctx 'Nothing 'PR
tenX = agree :> Do Breakdown :> Par FEngineers engineer :> Do Merge
