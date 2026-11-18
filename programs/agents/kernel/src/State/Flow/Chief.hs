{- | The chief flow: a loop of requests. Each request is routed once to a
whole flow, a block, a read-only discussion or a request no flow fits, runs
inline in this run, and ends in 'Result'; or it is handed whole to a child
run beside this one. Then the run takes the next request or ends, once
every such child has. A whole flow's branch and scope are its flow's name, so
a question asked inside it climbs from that flow's rung.
-}
module State.Flow.Chief (chief, chiefWith, ChiefS, discussion) where

import State.Category.Effect (Eff (FocusE, PickE), Handler (AgentPicks, FocusHere))
import State.Category.Flow (AgentRole (..), Branch (..), Branches (..), CapTarget (..), Flow (..), Group (..), Label (..), Name (..), Shape (..))
import State.Category.Fuel (PerFuel (..))
import State.Category.Meter (AtCap (..), Limit (..))
import State.Category.Ty (KnownTy, NotSum, TyOf (..))
import State.Flow.Architect (ArchitectS, architect)
import State.Flow.Engineer (EngineerS, engineer)
import State.Flow.Library (Blocks, BlocksS, BranchS, ChoiceS, DiscussS, blocks, branch, choice, discuss)
import State.Flow.TenX (TenXS, tenX)
import State.FlowName (FlowName (EngineerFlow), flowText)
import State.Step.Fuel (FuelStep (Fuel), Sing (Fuel))
import State.Step.Request (RequestStep (..), Sing (..))

{- | Each request sets its own Fuel, then is routed. Each request after the
first spends one: at the cap the user is asked whether to go on. The cap
is a guard against a runaway loop, not a budget: each request's own path
keeps its caps. A whole
flow's label is its flow's name ('State.FlowName.flowText'). A request's
steps raise 'FocusE', the user's attention: its handler suspends the
request in focus at any state and turns to another ("State.Run.Fold").
-}
chief :: Flow (HandleS PickE (HandleS FocusE ChiefS)) 'Ctx 'Nothing 'Result
chief = chiefWith architect

{- | The chief with this architect branch: the legacy chief
("State.Flow.Legacy") is the chief with the legacy architect.
-}
chiefWith :: (KnownTy o, NotSum o) => Flow a 'Ctx 'Nothing o -> Flow (HandleS PickE (HandleS FocusE (ChiefOf a))) 'Ctx 'Nothing 'Result
chiefWith architectFlow = Handle AgentPicks . Handle FocusHere $ Loop "requests" (Do Fuel :> choice "route" requests :> Capped (UpTo <$> PerFuel 50 100 200) Extend (Step Next)) :> Await delegates :> Into
  where
    requests =
        branch @"architect" architectFlow
            :& branch @"engineer" engineer
            :& branch @"10x" tenX
            :& (Label @"blocks" :-> choice "block" blocks)
            :& branch @"discussion" discuss
            :& (Label @"other" :-> Do Direct :> Into)
            :& (Label @"delegate" :-> Fork delegates engineer :> Into)
            :& End

{- | The requests handed on whole, each a child run beside the chief: its
init (@state init --parent@) at the fork is its spawn. An engineer's, or a
10x's: the child's own init names its flow, as the body is not drawn.
-}
delegates :: Group 'PR
delegates = Group "delegates" (AgentRole (flowText EngineerFlow))

type ChiefS = ChiefOf (HandleS PickE ArchitectS)

type ChiefOf :: Shape -> Shape
type ChiefOf a = LoopS (DoS Fuel :>> ChoiceS 'Ctx Requests (RequestsOf a) :>> CappedS (DoS Next)) :>> AwaitS :>> IntoS

-- | The routes of a request, each taking its context.
type Requests =
    '[ '("architect", 'Ctx)
     , '("engineer", 'Ctx)
     , '("10x", 'Ctx)
     , '("blocks", 'Ctx)
     , '("discussion", 'Ctx)
     , '("other", 'Ctx)
     , '("delegate", 'Ctx)
     ]

-- | The routes' flows, in 'Requests'' order, the architect's given: a whole flow handles its own effects.
type RequestsOf :: Shape -> [Shape]
type RequestsOf a =
    '[ BranchS a
     , BranchS (HandleS PickE EngineerS)
     , BranchS (HandleS PickE TenXS)
     , ChoiceS 'Ctx Blocks BlocksS
     , BranchS DiscussS
     , DoS Direct :>> IntoS
     , ForkS (HandleS PickE EngineerS) :>> IntoS
     ]

-- | The read-only discussion's branch and scope: "State.Role" runs it as the architect's.
discussion :: Name
discussion = "discussion"
