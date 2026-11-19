{- | #351's @Run(F)@: the free category on a flow's graph. A run is a path,
one transition per event, and @ty@ types it in @Cap@.
-}
module State.Category.Path (
    step,
    awaitDone,
    forkPasses,
    unrecorded,
    ty,
) where

import Control.Applicative ((<|>))
import Data.Map.Strict qualified as Map
import State.Category.Flow (FanEvent (..), fanEvent)
import State.Category.Graph (Arrow (..), Edge (..), GroupAt (..), Node (..), OpenGraph (..), Place, eachDoneOutcome, placeName)
import State.Category.Step (EventName (..), OutcomeEdge)

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

{- | The edge a 'State.Flow.Library.parallel''s fork state goes on by at once:
its 'State.Category.Flow.Each' forks one child per item, each started
later from the group's 'State.Category.Flow.Await' (the 10x spawns an
engineer once its task's dependencies merged), so no event records the
forks. 'Nothing' at any other state.
-}
forkPasses :: OpenGraph -> Place -> Maybe (Edge Node)
forkPasses g place = case Map.lookup place g.groupStates of
    Just (Forking _) -> step g place (EventName (placeName place) eachDoneOutcome)
    Just (Awaiting _) -> Nothing
    Nothing -> Nothing

-- | The edge a state goes on by with no event recording it: an await's done, a parallel's fork's.
unrecorded :: OpenGraph -> Place -> Maybe (Edge Node)
unrecorded g place = awaitDone g place <|> forkPasses g place

{- | @ty@ on the path the events walk from the in port: each
outcome to its edge of @Cap@, a child's hand-back at an await to the
identity, which a path of @Cap@ leaves out. An event past an await or a
parallel's fork walks its 'unrecorded' edge first. 'Nothing' when an event is not an edge where the path
has got to. Not a functor: it always walks from the in port, so a walk from
mid-flow has no @ty@. It keeps the empty walk and prefixes.
-}
ty :: OpenGraph -> [EventName] -> Maybe [OutcomeEdge]
ty g = go (At g.inPort)
  where
    go _ [] = Just []
    go node (event : rest) = case node of
        At place -> case (step g place event, unrecorded g place) of
            (Just edge, _) -> (arrowEdges edge.arrow <>) <$> go edge.to rest
            (Nothing, Just done) -> (arrowEdges done.arrow <>) <$> go done.to (event : rest)
            (Nothing, Nothing) -> Nothing
        Out -> Nothing
        Exit -> Nothing

arrowEdges :: Arrow -> [OutcomeEdge]
arrowEdges = \case
    Along edge -> [edge]
    Stay -> []
