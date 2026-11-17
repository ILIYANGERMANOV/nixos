{- | The chief flow: a loop of requests. Each request is routed once to a
whole flow, a block, a read-only discussion or a request no flow fits, runs
inline in this run, and ends in 'Result'. Then the run takes the next
request or ends. A whole flow's branch and scope are its flow's name, so a
question asked inside it climbs from that flow's rung.
-}
module State.Flow.Chief (chief, discussion) where

import Data.List.NonEmpty (NonEmpty (..))
import State.Category.Flow (Flow (..), Name (..))
import State.Category.Fuel (PerFuel (..))
import State.Category.Meter (AtCap (..), Limit (..))
import State.Category.Step (OutcomeName (..))
import State.Category.Ty (Ty (..))
import State.Flow.Architect (architect)
import State.Flow.Engineer (engineer)
import State.Flow.Library (blocks, branch, discuss)
import State.Flow.TenX (tenX)
import State.FlowName (FlowName (..), flowText)
import State.Step.Request (Sing (..))

-- | Each request after the first spends one: at the cap the user is asked whether to go on.
chief :: Flow 'Ctx 'Nothing 'Result
chief = Loop "requests" (Route "route" requests :> Capped (UpTo <$> PerFuel 5 10 20) Extend Next)
  where
    requests =
        branch (flowScope ArchitectFlow) architect
            :| [ branch (flowScope EngineerFlow) engineer
               , branch (flowScope TenXFlow) tenX
               , (OutcomeName "blocks", Route "block" blocks)
               , branch discussion discuss
               , (OutcomeName "other", Do Direct :> Into)
               ]
    flowScope = Name . flowText

-- | The read-only discussion's branch and scope: "State.Role" runs it as the architect's.
discussion :: Name
discussion = "discussion"
