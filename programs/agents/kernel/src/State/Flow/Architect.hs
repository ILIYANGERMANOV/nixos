{- | The architect flow: from an idea to a design, changing no code. One
discussion, the agent's choice each round: spawn a researcher on a fact gap,
ask the user design questions, or write the ticket, or edit it, any number
of times. @enough@ waits for every researcher, merges their notes and ends
the run, with or without a ticket: its end names the notes and the ticket's
url, if one was written.
-}
module State.Flow.Architect (architect, ArchitectS) where

import State.Category.Effect (Eff (PickE), Handler (AgentPicks))
import State.Category.Flow (Branch (..), Branches (..), CapTarget (..), Flow (..), Shape (..))
import State.Category.Meter (AtCap (..))
import State.Category.Ty (TyOf (..))
import State.Flow.Library (ResearchLoopS, designQuestions, designResearchers, researchLoop)
import State.Step.Fuel (FuelStep (Fuel), Sing (Fuel))
import State.Step.Gather (GatherStep (Discuss), Sing (Discuss))
import State.Step.Ticket (Sing (WriteTicket), TicketStep (WriteTicket))

architect :: Flow (HandleS PickE ArchitectS) 'Ctx 'Nothing 'Ctx
architect =
    Handle AgentPicks $
        Do Fuel
            :> researchLoop "architect" designResearchers (#discuss :-> Capped designQuestions Extend (Step Discuss) :& #ticket :-> Do WriteTicket :& End)

type ArchitectS =
    DoS Fuel
        :>> ResearchLoopS '[ '("discuss", 'Ctx), '("ticket", 'Ctx)] '[CappedS (DoS Discuss), DoS WriteTicket]
