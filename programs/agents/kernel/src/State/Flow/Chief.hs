{- | The chief flow: a loop of requests. Each request is routed once to a
whole flow, a block, a read-only discussion or a request no flow fits, runs
inline in this run, and ends in 'Result'. Then the run takes the next
request or ends. A whole flow's branch and scope are its flow's name, so a
question asked inside it climbs from that flow's rung.
-}
module State.Flow.Chief (chief, ChiefS, discussion) where

import State.Category.Flow (Branch (..), Branches (..), CapTarget (..), Flow (..), Label (..), Name (..), Shape (..))
import State.Category.Fuel (PerFuel (..))
import State.Category.Meter (AtCap (..), Limit (..))
import State.Category.Ty (TyOf (..))
import State.Flow.Architect (ArchitectS, architect)
import State.Flow.Engineer (EngineerS, engineer)
import State.Flow.Library (Blocks, BlocksS, BranchS, ChoiceS, DiscussS, Handled, blocks, branch, choice, discuss, handled)
import State.Flow.TenX (TenXS, tenX)
import State.Step.Fuel (FuelStep (Fuel), Sing (Fuel))
import State.Step.Request (RequestStep (..), Sing (..))

{- | Each request sets its own Fuel, then is routed. Each request after the
first spends one: at the cap the user is asked whether to go on. A whole
flow's label is its flow's name ('State.FlowName.flowText').
-}
chief :: Flow (Handled ChiefS) 'Ctx 'Nothing 'Result
chief = handled (Loop "requests" (Do Fuel :> choice "route" requests :> Capped (UpTo <$> PerFuel 5 10 20) Extend (Step Next)))
  where
    requests =
        branch @"architect" architect
            :& branch @"engineer" engineer
            :& branch @"10x" tenX
            :& (Label @"blocks" :-> choice "block" blocks)
            :& branch @"discussion" discuss
            :& (Label @"other" :-> Do Direct :> Into)
            :& End

type ChiefS = LoopS (DoS Fuel :>> ChoiceS 'Ctx Requests RequestsS :>> CappedS (DoS Next))

-- | The routes of a request, each taking its context.
type Requests =
    '[ '("architect", 'Ctx)
     , '("engineer", 'Ctx)
     , '("10x", 'Ctx)
     , '("blocks", 'Ctx)
     , '("discussion", 'Ctx)
     , '("other", 'Ctx)
     ]

-- | The routes' flows, in 'Requests'' order: a whole flow handles its own effects.
type RequestsS =
    '[ BranchS (Handled ArchitectS)
     , BranchS (Handled EngineerS)
     , BranchS (Handled TenXS)
     , ChoiceS 'Ctx Blocks BlocksS
     , BranchS DiscussS
     , DoS Direct :>> IntoS
     ]

-- | The read-only discussion's branch and scope: "State.Role" runs it as the architect's.
discussion :: Name
discussion = "discussion"
