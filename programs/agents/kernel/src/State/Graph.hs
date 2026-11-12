{- | The functor @graph@ of #351: a flow term to its open graph, by gluing.
One recursive 'graph' over the term makes the graph of @f :> g@ the 'glue' of
the two graphs (law Compositional). Keyed by (state, event), a graph names at
most one target per pair (law Deterministic); a pair glued twice is a 'Clash'.
-}
module State.Graph (
    OpenGraph (..),
    Place (..),
    Node (..),
    Edge (..),
    Arrow (..),
    LoopAt (..),
    Empty (..),
    Clash (..),
    graph,
    glue,
) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import State.Cap (EventName (..), KnownTy (..), OutcomeEdge (..), Outcomes (..), Step, Ty (..), outcomes, skippedOutcome, stepName)
import State.Flow (FanId, Flow (..), LoopId, OnEmpty (..), OptId, fanName)

{- | A state where a step, or a fan-out, runs next. The path is the step's
position in the term, so a step used twice is two states; the name is what
people read.
-}
data Place = Place {path :: [Int], name :: Text}
    deriving stock (Eq, Ord, Show)

{- | 'Out' and 'Exit' are the open ports: gluing identifies them with the
next block's 'Place'. 'Out' left in a whole flow's graph is its end.
-}
data Node = At Place | Out | Exit
    deriving stock (Eq, Ord, Show)

-- | What @ty@ sends an edge to.
data Arrow
    = Along OutcomeEdge
    | -- | @<step>.skipped@: a mode skipped this 'Opt', the identity.
      Skip OptId
    | -- | A child spawned or handed back inside a fan-out, the identity.
      Stay
    deriving stock (Eq, Show)

-- | @back@ names the loop whose next round this edge starts.
data Edge = Edge {to :: Node, arrow :: Arrow, back :: Maybe LoopId}
    deriving stock (Eq, Show)

-- | The untyped 'OnEmpty'.
data Empty = Stops | Exits
    deriving stock (Eq, Show)

{- | A loop's first state, where each round starts, and the states of its
body. Nested loops can share an entry (gather and plan both start at
@research@), so the body, not the entry, tells whether a run is inside a loop.
-}
data LoopAt = LoopAt {entry :: Place, onEmpty :: Empty, body :: Set Place}
    deriving stock (Eq, Show)

data OpenGraph = OpenGraph
    { inPort :: Place
    , edges :: Map (Place, EventName) Edge
    , loops :: Map LoopId LoopAt
    }
    deriving stock (Eq, Show)

data Clash
    = -- | Two edges leave one state on one event.
      SameEvent Place EventName
    | -- | One loop id twice: its rounds and fuel would mix.
      SameLoop LoopId
    deriving stock (Eq, Show)

graph :: Flow i e o -> Either Clash OpenGraph
graph = \case
    Do s -> Right (stepGraph s)
    f :> g -> do
        left <- graph f
        right <- graph g
        glue left right
    Loop loopId onEmpty body -> closeLoop loopId (empty onEmpty) =<< graph body
    Opt optId body -> skippable optId =<< graph body
    Par fan body -> Right (fanOut fan body)

{- | Series: the left graph's 'Out' becomes the right graph's in port, and the
two 'Exit's become one. The paths of each side get their own prefix, so no
state of one side is a state of the other, and only a loop id can clash.
-}
glue :: OpenGraph -> OpenGraph -> Either Clash OpenGraph
glue left right = do
    loops <- unionLoops first.loops second.loops
    pure
        OpenGraph
            { inPort = first.inPort
            , edges = Map.union (fmap into first.edges) second.edges
            , loops
            }
  where
    first = within 0 left
    second = within 1 right
    into edge = case edge.to of
        Out -> edge {to = At second.inPort}
        Exit -> edge
        At _ -> edge

-- | One state, one edge per outcome: an exit to 'Exit', the continuing one to 'Out'.
stepGraph :: forall i e o. (KnownTy i, KnownTy o) => Step i e o -> OpenGraph
stepGraph s =
    OpenGraph
        { inPort = place
        , edges = Map.fromList $ case outcomes s of
            Continues continue -> [edge continue Out (tyVal @o)]
            exits@(ExitsOr exit continue) -> [edge exit Exit (exitTy exits), edge continue Out (tyVal @o)]
        , loops = Map.empty
        }
  where
    place = Place [] (stepName s)
    edge outcome to cod =
        let event = EventName place.name outcome
         in ((place, event), Edge to (Along (OutcomeEdge event (tyVal @i) cod)) Nothing)

exitTy :: forall x. Outcomes ('Just x) -> Ty
exitTy (ExitsOr _ _) = tyVal @x

-- | The body's continue goes back to its in port; its exit is the loop's out.
closeLoop :: LoopId -> Empty -> OpenGraph -> Either Clash OpenGraph
closeLoop loopId onEmpty body = do
    loops <- unionLoops body.loops (Map.singleton loopId (LoopAt body.inPort onEmpty places))
    pure body {edges = fmap close body.edges, loops}
  where
    -- Every state has an edge out, so the keys hold them all.
    places = Set.fromList (body.inPort : map fst (Map.keys body.edges))
    close edge = case edge.to of
        Out -> edge {to = At body.inPort, back = Just loopId}
        Exit -> edge {to = Out}
        At _ -> edge

empty :: OnEmpty a b -> Empty
empty = \case
    StopOut -> Stops
    ExitOut -> Exits

-- | A skip edge from the body's in port to its out, named after its first state.
skippable :: OptId -> OpenGraph -> Either Clash OpenGraph
skippable optId body = do
    edges <- insertNew (body.inPort, event) (Edge Out (Skip optId) Nothing) body.edges
    pure body {edges}
  where
    event = EventName body.inPort.name skippedOutcome

{- | One state: each child runs the body as a run of its own, so the body is
not drawn here and gives only its types. Children are spawned and hand back
while the state stays; @done@ leaves it.
-}
fanOut :: forall a b. (KnownTy a, KnownTy b) => FanId -> Flow a 'Nothing b -> OpenGraph
fanOut fan _ =
    OpenGraph
        { inPort = place
        , edges =
            Map.fromList
                [ edge "spawned" (Edge (At place) Stay Nothing)
                , edge "handed_back" (Edge (At place) Stay Nothing)
                , edge "done" (Edge Out (Along (OutcomeEdge (event "done") (List (tyVal @a)) (List (tyVal @b)))) Nothing)
                ]
        , loops = Map.empty
        }
  where
    place = Place [] (fanName fan)
    event = EventName place.name
    edge outcome target = ((place, event outcome), target)

-- | Prefixes every path, so the graph can sit beside another.
within :: Int -> OpenGraph -> OpenGraph
within branch g =
    OpenGraph
        { inPort = moved g.inPort
        , edges = Map.fromList [((moved from, event), edge {to = node edge.to}) | ((from, event), edge) <- Map.toList g.edges]
        , loops = fmap (\at -> at {entry = moved at.entry, body = Set.map moved at.body}) g.loops
        }
  where
    moved p = p {path = branch : p.path}
    node = \case
        At p -> At (moved p)
        Out -> Out
        Exit -> Exit

unionLoops :: Map LoopId LoopAt -> Map LoopId LoopAt -> Either Clash (Map LoopId LoopAt)
unionLoops left right = case Map.keys (Map.intersection left right) of
    [] -> Right (Map.union left right)
    loopId : _ -> Left (SameLoop loopId)

insertNew :: (Place, EventName) -> Edge -> Map (Place, EventName) Edge -> Either Clash (Map (Place, EventName) Edge)
insertNew key@(place, event) edge = Map.alterF (maybe (Right (Just edge)) (const (Left (SameEvent place event)))) key
