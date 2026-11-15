{- | The 10x flow of #351: agree on a plan, break it into tasks, run an
engineer per task, and merge their PRs into one. A round that leaves its PRs
open loops back to agree on the next round's plan, in the same run.
-}
module State.Flow.TenX (tenX) where

import State.Category.Flow (Flow (..), OnEmpty (..))
import State.Category.Fuel (always)
import State.Category.Ty (Ty (..))
import State.Flow.Engineer (engineer)
import State.Flow.Library (agree)
import State.Step.Fan (Sing (Breakdown, Merge), engineers)

-- | Rounds are a cap only, so a stuck @next_round@ loop ends: 10 is generous for rounds on one PR.
tenX :: Flow 'Ctx 'Nothing 'PR
tenX = Loop "round" (always 10) StopOut (agree :> Do (Breakdown engineers) :> Par engineers engineer :> Do (Merge engineers))
