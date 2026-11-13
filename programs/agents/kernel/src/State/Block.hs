{- | #351's block catalog: the typed pieces the flows glue. Each is a block
the skills share today, so a flow names the blocks rather than their steps.
-}
module State.Block (
    agree,
    gather,
    propose,
    build,
    review,
    describe,
    ship,
) where

import State.Category.Flow (Flow (..), LoopId (..), OnEmpty (..), OptId (..))
import State.Category.Ty (Ty (..))
import State.Step.Build (Sing (..))
import State.Step.Gather (Sing (..))
import State.Step.Plan (Sing (..))
import State.Step.Review (Sing (..))
import State.Step.Ship (Sing (..))

{- | Gather and propose until a plan is confirmed: both flows open with it.
Out of fuel is a stop, as an adjusted plan that never settles needs the user.
-}
agree :: Flow 'Ctx 'Nothing 'Plan
agree = Loop LPlan StopOut (gather :> propose)

-- | Research, then interview, until the interview has enough.
gather :: Flow 'Ctx 'Nothing 'Ctx
gather = Loop LGather StopOut (Opt ORes (Do Research) :> Do Interview)

-- | A confirmed plan exits; an adjusted one goes back to gathering.
propose :: Flow 'Ctx ('Just 'Plan) 'Ctx
propose =
    Do PlanS
        :> Opt OSimp (Do SimplifyP)
        :> Opt OAlt (Do Alternative)
        :> Do Confirm

-- | @draft@ opens the draft PR before the first commit.
build :: Flow 'Plan 'Nothing 'Diff
build = Do Draft :> Do Implement :> Opt ORefactor (Do Refactor)

{- | Review is its own block, one 'Diff' in and one out, so another flow can
glue it in: whoever does supplies the requirements the diff must meet. Out of
fuel takes the exit rather than stopping, as #351 decided.
-}
review :: Flow 'Diff 'Nothing 'Diff
review = Loop LReview ExitOut (Do Review :> Do Pick :> Do Fix)

-- | @describe@ is the final fixer, so it is no 'Opt': the Keep law.
describe :: Flow 'Diff 'Nothing 'PR
describe = Do Describe :> Opt OBody (Do SimplifyPR)

ship :: Flow 'PR 'Nothing 'PR
ship = Loop LCi StopOut (Do AwaitCi :> Do FixPR) :> Opt OReady (Do Ready)
