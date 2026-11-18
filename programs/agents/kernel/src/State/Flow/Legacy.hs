{- | The flows as they were before the architect became one discussion
(#479): a log the current graph does not replay replays under its flow's
legacy graph, so an old run, finished or not, goes on in the flow it started
in. A log of an old-only event (@problem.*@, @confirm_design.*@, or the
architect's old @exploring@ loop) has no edge in the current graph, and a
log of only its first lines is the same in both, so the current graph takes
every new run. Delete this module once no old run is live.

The legacy architect: research, then the problem talked through with the
user until they say it is understood; then design rounds, each discussed and
confirmed with the user, and only the confirmed design written into a
ticket, once. Each loop goes up to three rounds before the user is asked
whether to go on.
-}
module State.Flow.Legacy (legacyGraph, legacyArchitect) where

import State.Category.Effect (Eff (PickE), Handler (AgentPicks))
import State.Category.Flow (CapTarget (..), Flow (..), Shape (..))
import State.Category.Graph (OpenGraph, graph)
import State.Category.Meter (AtCap (..))
import State.Category.Ty (TyOf (..))
import State.Flow.Chief (chiefWith)
import State.Flow.Library (DiscussS, ResearchS, designResearchers, discuss, research, upTo)
import State.FlowName (FlowName (..))
import State.Step.Fuel (FuelStep (Fuel), Sing (Fuel))
import State.Step.Ticket (Sing (..), TicketStep (..))

-- | The legacy graph of a flow that has one: the architect's and the chief's, which runs it.
legacyGraph :: FlowName -> Maybe OpenGraph
legacyGraph = \case
    ArchitectFlow -> Just (glued (graph legacyArchitect))
    ChiefFlow -> Just (glued (graph (chiefWith legacyArchitect)))
    EngineerFlow -> Nothing
    TenXFlow -> Nothing
  where
    -- As every flow's graph, its test holds that it glues.
    glued = either (error . ("the legacy flow does not glue: " <>) . show) id

legacyArchitect :: Flow (HandleS PickE LegacyArchitectS) 'Ctx 'Nothing 'Ticket
legacyArchitect =
    Handle AgentPicks $
        Do Fuel
            :> Loop "understanding" (research designResearchers :> upTo 3 Extend (Step Problem))
            :> Loop "design" (discuss :> upTo 3 Extend (Step ConfirmDesign))

type LegacyArchitectS =
    DoS Fuel
        :>> LoopS (ResearchS :>> CappedS (DoS Problem))
        :>> LoopS (DiscussS :>> CappedS (DoS ConfirmDesign))
