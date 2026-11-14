{- | The functor @graph@ of #351: a flow term to its open graph, by gluing.
One recursive pass over the term makes the graph of @f :> g@ the 'glue' of
the two graphs (law Compositional). Keyed by (state, event), a graph names at
most one target per pair (law Deterministic); a pair glued twice is a 'Clash'.
Inside the term a part's ports are typed: one in port per summand of its in,
an out edge names the summand of its out it continues into, so gluing a case
after a step that branches connects each branch to its own leg.
-}
module State.Category.Graph (
    OpenGraph (..),
    Place (..),
    Node (..),
    Edge (..),
    Arrow (..),
    LoopAt (..),
    Empty (..),
    Clash (..),
    graph,
    places,
) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import State.Category.Flow (FanEvent (..), FanId, Flow (..), LoopId, OnEmpty (..), OptId, fanEvent, fanName)
import State.Category.Step (EventName (..), OutcomeEdge (..), OutcomeName, Outcomes (..), Sig, Sing, StateName, StepSet, outcomes, skippedOutcome, stepName)
import State.Category.Ty (IsSum, KnownTy (..), NotSum, Ty (..))

{- | A state where a step, or a fan-out, runs next. The path is the step's
position in the term, so a step used twice is two states; the name is what
people read.
-}
data Place = Place {path :: [Int], name :: StateName}
    deriving stock (Eq, Ord, Show)

-- | Where an edge of a whole flow's graph goes: a state, its end, or its exit.
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

-- | @back@ names the loop whose next round this edge starts. @n@ is where it goes: a 'Node' in a whole flow.
data Edge n = Edge {to :: n, arrow :: Arrow, back :: Maybe LoopId}
    deriving stock (Eq, Show, Functor)

-- | The untyped 'OnEmpty'.
data Empty = Stops | Exits
    deriving stock (Eq, Show)

{- | A loop's first state, where each round starts, and the states of its
body. Nested loops can share an entry (gather and plan both start at
@research@), so the body, not the entry, tells whether a run is inside a loop.
-}
data LoopAt = LoopAt {entry :: Place, onEmpty :: Empty, body :: Set Place}
    deriving stock (Eq, Show)

-- | A whole flow's graph: it starts at one state, and its edges end at a state, its end or its exit.
data OpenGraph = OpenGraph
    { inPort :: Place
    , edges :: Map (Place, EventName) (Edge Node)
    , loops :: Map LoopId LoopAt
    }
    deriving stock (Eq, Show)

data Clash
    = -- | Two edges leave one state on one event.
      SameEvent Place EventName
    | -- | One loop id twice: its rounds and fuel would mix.
      SameLoop LoopId
    deriving stock (Eq, Show)

{- | A whole flow starts from one type and ends in one, so it has one in port
and one end. Its graph holds only the states a run can reach: a branch an
injection never takes (@inl :> (f ||| g)@ never runs @g@) is not drawn.
-}
graph :: (NotSum i, NotSum o) => Flow i e o -> Either Clash OpenGraph
graph flow = whole <$> part flow

whole :: (NotSum i, NotSum o) => Part i o -> OpenGraph
whole p =
    OpenGraph
        { inPort
        , edges = Map.filterWithKey (\(from, _) _ -> Set.member from reached) edges
        , loops = Map.mapMaybe (\at -> if Set.member at.entry reached then Just at {body = Set.intersection at.body reached} else Nothing) p.loops
        }
  where
    inPort = entryOf p
    edges = fmap (fmap node) p.edges
    reached = reachable inPort edges
    node = \case
        ToState place -> At place
        ToOut _ -> Out
        ToExit -> Exit

-- | The states a walk from this one can reach.
reachable :: Place -> Map (Place, EventName) (Edge Node) -> Set Place
reachable start edges = go Set.empty [start]
  where
    go seen = \case
        [] -> seen
        place : rest
            | Set.member place seen -> go seen rest
            | otherwise -> go (Set.insert place seen) ([next | ((from, _), Edge {to = At next}) <- Map.toList edges, from == place] <> rest)

{- | Which summand of @t@ an edge continues into, down to one type. 'Here' at
a sum does not type-check, so every selector names one in port. Its context
is the equality, not 'NotSum': building a 'Here' from a 'NotSum' given then
forces that evidence, so a refusal deferred to run time fires when drawn.
-}
data Sel (t :: Ty) where
    Here :: (IsSum t ~ 'False) => Sel t
    SL :: Sel a -> Sel (a ':+ b)
    SR :: Sel b -> Sel (a ':+ b)

-- | Where an edge of a part goes: a state, a summand of the part's out, or its exit.
data To o = ToState Place | ToOut (Sel o) | ToExit

{- | Where a summand of a part's in enters: a state, or straight on to a
summand of its out, as an injection does. Only a part whose out is a sum
passes one on: every part that ends in one type runs a step on the way.
-}
data Entry o where
    Enters :: Place -> Entry o
    Passes :: (IsSum o ~ 'True) => Sel o -> Entry o

-- | The graph of a term inside a flow: one in port per summand of @i@, out edges typed by summand of @o@.
data Part i o = Part
    { inPorts :: Sel i -> Entry o
    , edges :: Map (Place, EventName) (Edge (To o))
    , loops :: Map LoopId LoopAt
    }

part :: Flow i e o -> Either Clash (Part i o)
part = \case
    Do s -> Right (stepPart s)
    f :> g -> do
        left <- part f
        right <- part g
        glue left right
    Loop loopId onEmpty body -> closeLoop loopId (empty onEmpty) =<< part body
    Opt optId body -> skippable optId =<< part body
    Par fan body -> Right (fanOut fan body)
    InL -> Right (passing SL)
    InR -> Right (passing SR)
    f :||| g -> do
        left <- part f
        right <- part g
        copair left right

{- | Series: each of the left part's out edges goes on to the in port of the
right part's summand it names, and the two exits become one. The paths of
each side get their own prefix, so no state of one side is a state of the
other, and only a loop id can clash.
-}
glue :: Part a b -> Part b c -> Either Clash (Part a c)
glue left right = do
    loops <- unionLoops first.loops second.loops
    pure
        Part
            { inPorts = \sel -> case first.inPorts sel of
                Enters place -> Enters place
                Passes on -> second.inPorts on
            , edges = Map.union (fmap (fmap into) first.edges) second.edges
            , loops
            }
  where
    first = within 0 left
    second = within 1 right
    into = \case
        ToOut sel -> case second.inPorts sel of
            Enters place -> ToState place
            Passes on -> ToOut on
        ToState place -> ToState place
        ToExit -> ToExit

-- | Case: the left part takes the left summand's in ports, the right part the right's.
copair :: Part a c -> Part b c -> Either Clash (Part (a ':+ b) c)
copair left right = do
    loops <- unionLoops first.loops second.loops
    pure
        Part
            { inPorts = \case
                SL sel -> first.inPorts sel
                SR sel -> second.inPorts sel
            , edges = Map.union first.edges second.edges
            , loops
            }
  where
    first = within 0 left
    second = within 1 right

-- | An injection: no state, each summand of its in passes on to its summand of the out.
passing :: (IsSum o ~ 'True) => (Sel i -> Sel o) -> Part i o
passing inject = Part {inPorts = Passes . inject, edges = Map.empty, loops = Map.empty}

{- | One state, one edge per outcome: an exit to the exit, a continuing one to
the out, or to its summand of the out when the step branches.
-}
stepPart :: forall k (s :: k) i e o. (StepSet k, Sig s ~ '(i, e, o), KnownTy i, KnownTy o, NotSum i) => Sing s -> Part i o
stepPart s =
    Part
        { inPorts = \Here -> Enters place
        , edges = Map.fromList $ case outcomes s of
            Continues continue -> [edge continue (ToOut Here) (tyVal @o)]
            exits@(ExitsOr exit continue) -> [edge exit ToExit (exitTy exits), edge continue (ToOut Here) (tyVal @o)]
            branches@(Branches left right) ->
                let (leftTy, rightTy) = summandTys branches
                 in [edge left (ToOut (SL Here)) leftTy, edge right (ToOut (SR Here)) rightTy]
        , loops = Map.empty
        }
  where
    place = Place [] (stepName s)
    edge :: OutcomeName -> To o -> Ty -> ((Place, EventName), Edge (To o))
    edge outcome to cod =
        let event = EventName place.name outcome
         in ((place, event), Edge to (Along (OutcomeEdge event (tyVal @i) cod)) Nothing)

exitTy :: forall x o. Outcomes ('Just x) o -> Ty
exitTy (ExitsOr _ _) = tyVal @x

summandTys :: forall a b. Outcomes 'Nothing (a ':+ b) -> (Ty, Ty)
summandTys (Branches _ _) = (tyVal @a, tyVal @b)

-- | The body's continue goes back to its in port; its exit is the loop's out.
closeLoop :: (NotSum a, NotSum b) => LoopId -> Empty -> Part a a -> Either Clash (Part a b)
closeLoop loopId onEmpty body = do
    loops <- unionLoops body.loops (Map.singleton loopId (LoopAt entry onEmpty (sources body.edges)))
    pure Part {inPorts = \Here -> Enters entry, edges = fmap closed body.edges, loops}
  where
    entry = entryOf body
    closed edge = case edge.to of
        ToOut _ -> Edge (ToState entry) edge.arrow (Just loopId)
        ToExit -> Edge (ToOut Here) edge.arrow edge.back
        ToState place -> Edge (ToState place) edge.arrow edge.back

empty :: OnEmpty a b -> Empty
empty = \case
    StopOut -> Stops
    ExitOut -> Exits

-- | A skip edge from the body's in port to its out, named after its first state.
skippable :: (NotSum a) => OptId -> Part a a -> Either Clash (Part a a)
skippable optId body = do
    edges <- insertNew (entry, event) (Edge (ToOut Here) (Skip optId) Nothing) body.edges
    pure Part {inPorts = body.inPorts, edges, loops = body.loops}
  where
    entry = entryOf body
    event = EventName entry.name skippedOutcome

-- | The state a part over one type starts at: it runs a step before it ends, as 'Entry' holds.
entryOf :: (NotSum a, NotSum o) => Part a o -> Place
entryOf p = case p.inPorts Here of
    Enters place -> place

{- | One state: each child runs the body as a run of its own, so the body is
not drawn here and gives only its types. Children are spawned and hand back
while the state stays; @done@ leaves it, once every task is settled
("State.Run.Fan"). The parent logs the stay events under the bare names
@spawned@ and @handed_back@: they carry the child, not an outcome.
-}
fanOut :: forall a b. (KnownTy a, KnownTy b) => FanId -> Flow a 'Nothing b -> Part ('List a) ('List b)
fanOut fan _ =
    Part
        { inPorts = \Here -> Enters place
        , edges =
            Map.fromList
                [ edge Spawns (Edge (ToState place) Stay Nothing)
                , edge HandsBack (Edge (ToState place) Stay Nothing)
                , edge Leaves (Edge (ToOut Here) (Along (OutcomeEdge (fanEvent Leaves place.name) (List (tyVal @a)) (List (tyVal @b)))) Nothing)
                ]
        , loops = Map.empty
        }
  where
    place = Place [] (fanName fan)
    edge event target = ((place, fanEvent event place.name), target)

-- | The graph's states. Every state has an edge out, so the edges' keys hold them all.
places :: OpenGraph -> Set Place
places g = sources g.edges

-- | The states these edges leave.
sources :: Map (Place, EventName) a -> Set Place
sources edges = Set.fromList (map fst (Map.keys edges))

-- | Prefixes every path, so the part can sit beside another.
within :: Int -> Part i o -> Part i o
within branch p =
    Part
        { inPorts = \sel -> case p.inPorts sel of
            Enters place -> Enters (moved place)
            Passes on -> Passes on
        , edges = Map.fromList [((moved from, event), fmap node edge) | ((from, event), edge) <- Map.toList p.edges]
        , loops = fmap (\at -> at {entry = moved at.entry, body = Set.map moved at.body}) p.loops
        }
  where
    moved place = place {path = branch : place.path}
    node = \case
        ToState place -> ToState (moved place)
        ToOut sel -> ToOut sel
        ToExit -> ToExit

unionLoops :: Map LoopId LoopAt -> Map LoopId LoopAt -> Either Clash (Map LoopId LoopAt)
unionLoops left right = case Map.keys (Map.intersection left right) of
    [] -> Right (Map.union left right)
    loopId : _ -> Left (SameLoop loopId)

insertNew :: (Place, EventName) -> Edge n -> Map (Place, EventName) (Edge n) -> Either Clash (Map (Place, EventName) (Edge n))
insertNew key@(place, event) edge = Map.alterF (maybe (Right (Just edge)) (const (Left (SameEvent place event)))) key
