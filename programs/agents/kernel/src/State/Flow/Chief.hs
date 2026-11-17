{- | The chief flow: a loop of requests. Each request is routed once to a
whole flow, a block, a read-only discussion or a request no flow fits, runs
inline in this run, and ends in 'Result'. Then the run takes the next
request or ends. A whole flow's branch and scope are its flow's name, so a
question asked inside it climbs from that flow's rung.
-}
module State.Flow.Chief (chief, discussion) where

import State.Category.Flow (Branch (..), Branches (..), Flow (..), Label (..), Name (..))
import State.Category.Fuel (PerFuel (..))
import State.Category.Meter (AtCap (..), Limit (..))
import State.Category.Ty (TyOf (..))
import State.Flow.Architect (architect)
import State.Flow.Engineer (engineer)
import State.Flow.Library (blocks, branch, choice, discuss)
import State.Flow.TenX (tenX)
import State.Step.Fuel (Sing (Fuel))
import State.Step.Request (Sing (..))

{- | Each request sets its own Fuel, then is routed. Each request after the
first spends one: at the cap the user is asked whether to go on. A whole
flow's label is its flow's name ('State.FlowName.flowText').
-}
chief :: Flow 'Ctx 'Nothing 'Result
chief = Loop "requests" (Do Fuel :> choice "route" requests :> Capped (UpTo <$> PerFuel 5 10 20) Extend Next)
  where
    requests =
        branch @"architect" architect
            :& branch @"engineer" engineer
            :& branch @"10x" tenX
            :& (Label @"blocks" :-> choice "block" blocks)
            :& branch @"discussion" discuss
            :& (Label @"other" :-> Do Direct :> Into)
            :& End

-- | The read-only discussion's branch and scope: "State.Role" runs it as the architect's.
discussion :: Name
discussion = "discussion"
