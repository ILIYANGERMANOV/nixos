{- | #351's @Run(F)@: the free category on a flow's graph. A run is a path,
one transition per event, and @ty@ types it in @Cap@.
-}
module State.Category.Path (
    step,
    awaitDone,
    ty,
) where

import Data.Map.Strict qualified as Map
import State.Category.Flow (FanEvent (..), fanEvent)
import State.Category.Graph (Arrow (..), Edge (..), GroupAt (..), Node (..), OpenGraph (..), Place, placeName)
import State.Category.Step (EventName, OutcomeEdge)

-- | The one edge an event takes from a state, if the flow has it there.
step :: OpenGraph -> Place -> EventName -> Maybe (Edge Node)
step g place event = Map.lookup (place, event) g.edges

{- | The edge a group's 'State.Category.Flow.Await' goes on by once every
child handed back: no event records it. 'Nothing' at any other state.
-}
awaitDone :: OpenGraph -> Place -> Maybe (Edge Node)
awaitDone g place = case Map.lookup place g.groupStates of
    Just (Awaiting _) -> step g place (fanEvent Leaves (placeName place))
    Just (Forking _) -> Nothing
    Nothing -> Nothing

{- | The functor @ty@ on the path the events walk from the in port: each
outcome to its edge of @Cap@, a skip and a fan-out's inner events to the
identity, which a path of @Cap@ leaves out. An event past an await walks
its 'awaitDone' first. 'Nothing' when an event is not an edge where the path
has got to.
-}
ty :: OpenGraph -> [EventName] -> Maybe [OutcomeEdge]
ty g = go (At g.inPort)
  where
    go _ [] = Just []
    go node (event : rest) = case node of
        At place -> case (step g place event, awaitDone g place) of
            (Just edge, _) -> (arrowEdges edge.arrow <>) <$> go edge.to rest
            (Nothing, Just done) -> (arrowEdges done.arrow <>) <$> go done.to (event : rest)
            (Nothing, Nothing) -> Nothing
        Out -> Nothing
        Exit -> Nothing

arrowEdges :: Arrow -> [OutcomeEdge]
arrowEdges = \case
    Along edge -> [edge]
    Stay -> []
