{- | #351's @Run(F)@: the free category on a flow's graph. A run is a path,
one transition per event, and @ty@ types it in @Cap@.
-}
module State.Category.Path (
    step,
    ty,
) where

import Data.Map.Strict qualified as Map
import State.Category.Graph (Arrow (..), Edge (..), Node (..), OpenGraph (..), Place)
import State.Category.Step (EventName, OutcomeEdge)

-- | The one edge an event takes from a state, if the flow has it there.
step :: OpenGraph -> Place -> EventName -> Maybe (Edge Node)
step g place event = Map.lookup (place, event) g.edges

{- | The functor @ty@ on the path the events walk from the in port: each
outcome to its edge of @Cap@, a skip and a fan-out's inner events to the
identity, which a path of @Cap@ leaves out. 'Nothing' when an event is not an
edge where the path has got to.
-}
ty :: OpenGraph -> [EventName] -> Maybe [OutcomeEdge]
ty g = go (At g.inPort)
  where
    go _ [] = Just []
    go node (event : rest) = case node of
        At place -> do
            edge <- step g place event
            (arrowEdges edge.arrow <>) <$> go edge.to rest
        Out -> Nothing
        Exit -> Nothing

arrowEdges :: Arrow -> [OutcomeEdge]
arrowEdges = \case
    Along edge -> [edge]
    Skip _ -> []
    Stay -> []
