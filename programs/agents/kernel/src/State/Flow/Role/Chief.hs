{- | The chief flow: a loop of requests. Each request is routed once to a
whole flow, a block, a read-only discussion or a request no flow fits, runs
inline in this run, and ends in 'Result'; or it is handed whole to a child
run beside this one. Then the run takes the next request or ends, once
every such child has. A whole flow's branch and scope are its flow's name, so
a question asked inside it climbs from that flow's rung.
-}
module State.Flow.Role.Chief (
    chief,
    ChiefS,
    discussion,
    blocks,
    Blocks,
    BlocksS,
) where

import State.Category.Effect (
    Eff (FocusE, PickE),
    Handler (FocusHandler, PickHandler),
 )
import State.Category.Flow (
    AgentRole (..),
    Branch (..),
    Branches (..),
    CapTarget (..),
    Flow (..),
    Group (..),
    Label (..),
    Name (..),
    Shape (..),
 )
import State.Category.Fuel (PerFuel (..))
import State.Category.Meter (AtCap (..), Limit (..))
import State.Category.Ty (TyOf (..))
import State.Flow.Block (
    AgreeS,
    BuildS,
    DescribeS,
    DiscussS,
    GatherS,
    ProposeS,
    ResearchS,
    ReviewS,
    ShipS,
    agree,
    build,
    describe,
    discuss,
    gather,
    gatherResearcherLimit,
    propose,
    research,
    review,
    ship,
 )
import State.Flow.Combinator (BranchS, ChoiceS, branch, choice)
import State.Flow.Role.Architect (ArchitectS, architect)
import State.Flow.Role.Engineer (EngineerS, engineer)
import State.Flow.Role.TenX (TenXS, tenX)
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
chief =
    Handle PickHandler . Handle FocusHandler $
        Loop
            "requests"
            ( Do Fuel
                :> choice "route" requests
                :> Capped (UpTo <$> PerFuel 50 100 200) Extend (Step Next)
            )
            :> Await delegates
            :> Into
  where
    requests =
        branch @"architect" architect
            :& branch @"engineer" engineer
            :& branch @"10x" tenX
            :& (Label @"blocks" :-> choice "block" blocks)
            :& branch @"discussion" (discuss "discussing" End)
            :& (Label @"other" :-> Do Direct :> Into)
            :& (Label @"delegate" :-> Fork delegates engineer :> Into)
            :& End
    -- The requests handed on whole, each a child run beside the chief: its
    -- init (@state init --parent@) at the fork is its spawn. An engineer's, or a
    -- 10x's: the child's own init names its flow, as the body is not drawn.
    delegates :: Group 'PR
    delegates = Group "delegates" (AgentRole (flowText EngineerFlow))

type ChiefS =
    LoopS (DoS Fuel :>> ChoiceS 'Ctx Requests RequestFlows :>> CappedS (DoS Next))
        :>> AwaitS
        :>> IntoS

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

-- | The routes' flows, in 'Requests'' order: a whole flow handles its own effects.
type RequestFlows :: [Shape]
type RequestFlows =
    '[ BranchS (HandleS PickE ArchitectS)
     , BranchS (HandleS PickE EngineerS)
     , BranchS (HandleS PickE TenXS)
     , ChoiceS 'Ctx Blocks BlocksS
     , BranchS (DiscussS '[] '[])
     , DoS Direct :>> IntoS
     , ForkS (HandleS PickE EngineerS) :>> IntoS
     ]

-- | The read-only discussion's branch and scope: "State.Role" runs it as the architect's.
discussion :: Name
discussion = "discussion"

{- | Each block a request may run alone, as a branch of a 'choice': a block
that starts past 'Ctx' opens its input first, from the issue, branch or PR
the request names. Each sits in a scope of its branch's label, so its states
never meet a whole flow's, and ends in 'Result'.
-}
blocks :: Branches BlocksS Blocks 'Nothing 'Result
blocks =
    branch @"researching" (research gatherResearcherLimit)
        :& branch @"gathering" gather
        :& branch @"agreeing" agree
        :& branch @"proposing" (Loop "proposals" propose)
        :& branch @"building" (Do OpenPlan :> build)
        :& branch @"reviewing" (Do OpenBranch :> review)
        :& branch @"describing" (Do OpenBranch :> describe)
        :& branch @"shipping" (Do OpenPr :> ship)
        :& End

-- | The blocks' flows, in 'Blocks'' order.
type BlocksS =
    '[ BranchS ResearchS
     , BranchS GatherS
     , BranchS AgreeS
     , BranchS (LoopS ProposeS)
     , BranchS (DoS OpenPlan :>> BuildS)
     , BranchS (DoS OpenBranch :>> ReviewS)
     , BranchS (DoS OpenBranch :>> DescribeS)
     , BranchS (DoS OpenPr :>> ShipS)
     ]

-- | The blocks' labels, each taking the request's context.
type Blocks =
    '[ '("researching", 'Ctx)
     , '("gathering", 'Ctx)
     , '("agreeing", 'Ctx)
     , '("proposing", 'Ctx)
     , '("building", 'Ctx)
     , '("reviewing", 'Ctx)
     , '("describing", 'Ctx)
     , '("shipping", 'Ctx)
     ]
