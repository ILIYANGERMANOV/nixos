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
    placeName,
    Node (..),
    Edge (..),
    Arrow (..),
    LoopAt (..),
    Cap (..),
    Metered (..),
    shownOrder,
    Clash (..),
    graph,
    places,
    innermost,
    leaving,
    eventLabel,
    isRouteHub,
) where

import Control.Monad (foldM)
import Data.Foldable (minimumBy, toList)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Ord (comparing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import State.Category.Flow (FanEvent (..), Flow (..), Name (..), ScopePath, enoughOutcome, fanEvent, namedState, qualify, qualifyEvent, scopePath, scoped)
import State.Category.Fuel (PerFuel, SkipWhen)
import State.Category.Meter (AtCap (..), Limit, Meter, SomeMeter (..))
import State.Category.Step (EventName (..), OutcomeEdge (..), OutcomeName (..), Outcomes (..), Sig, Sing, StateName (..), StepSet, eventText, handedBackOutcome, outcomes, skippedOutcome, spawnedOutcome, stepName)
import State.Category.Ty (IsSum, KnownTy (..), NotSum, Ty (..))

{- | A state where a step, or a fan-out, runs next. The path is the step's
position in the term, so a step used twice is two states. The name is its
step's, or its fan-out's, inside the scopes around it: 'placeName' is what
people and the log read.
-}
data Place = Place {path :: [Int], scope :: ScopePath, name :: StateName}
    deriving stock (Eq, Ord, Show)

-- | @security/review@: the state's name inside its scopes, as its events and overrides name it.
placeName :: Place -> StateName
placeName place = qualify place.scope place.name

-- | Where an edge of a whole flow's graph goes: a state, its end, or its exit.
data Node = At Place | Out | Exit
    deriving stock (Eq, Ord, Show)

-- | What @ty@ sends an edge to.
data Arrow
    = Along OutcomeEdge
    | -- | @<step>.skipped@: a level skipped this 'Opt', the identity, when its 'SkipWhen' lets it.
      Skip Name (PerFuel SkipWhen)
    | -- | A child spawned or handed back inside a fan-out or a choice, the identity.
      Stay
    deriving stock (Eq, Show)

-- | @back@ names the loop whose next round this edge starts. @n@ is where it goes: a 'Node' in a whole flow.
data Edge n = Edge {to :: n, arrow :: Arrow, back :: Maybe Name}
    deriving stock (Eq, Show, Functor)

{- | A loop's first state, where each round starts, and the states of its
body. Nested loops can share an entry (the plan's loop and the gather's
choice both start at @gather@), so the body, not the entry, tells whether a
run is inside a loop.
-}
data LoopAt = LoopAt {entry :: Place, body :: Set Place}
    deriving stock (Eq, Show)

{- | A 'Capped' step's budget at its state: its step's meter, the limit at
each Fuel, what a spend past it does, and its rank among the caps at that
state as the term declares them: a choice's actions are shown in that order
(0 for a step's own cap). The rank is presentation only: the choice's
law says the actions' order changes nothing else.
-}
data Cap = Cap {meter :: SomeMeter, limit :: PerFuel Limit, atCap :: AtCap, rank :: Int}
    deriving stock (Eq, Show)

{- | Where a 'Capped' step's budget is spent: at its own state, or, as a
choice's action, at the choice's, beside its other actions.
-}
data Metered = Metered {place :: Place, step :: StateName}
    deriving stock (Eq, Ord, Show)

-- | The order caps are shown in: by state, in the term's order, then by rank.
shownOrder :: Metered -> Cap -> (Place, Int)
shownOrder metered cap = (metered.place, cap.rank)

-- | A whole flow's graph: it starts at one state, and its edges end at a state, its end or its exit.
data OpenGraph = OpenGraph
    { inPort :: Place
    , edges :: Map (Place, EventName) (Edge Node)
    , loops :: Map Name LoopAt
    , caps :: Map Metered Cap
    , routes :: Set Place
    -- ^ Each 'Route''s hub, where the run picks a branch.
    }
    deriving stock (Eq, Show)

data Clash
    = -- | Two edges leave one state on one event.
      SameEvent Place EventName
    | -- | One loop name twice: its rounds would mix.
      SameLoop Name
    | -- | One fan-out name twice: a run keeps one fan-out's tasks per name.
      SameFan Name
    | {- | A whole flow, or a loop's body, that runs no step: a run would
      have no state to start at, or a round none to end at.
      -}
      NoStep
    | -- | A loop whose body caps no step of its own: nothing bounds its rounds.
      Unbounded Name
    | {- | A step capped by 'Refuse' with no edge out of its innermost loop:
      past the cap its spend is refused and nothing is left to record.
      -}
      RefuseWithoutWayOut Place
    | {- | A choice's branch that is not a 'Capped' step whose events stay at
      the choice ('State.Category.Step.OpensChildren' or
      'State.Category.Step.AsksOnly'): it would leave the choice.
      -}
      NotAnAction Name
    | -- | One action twice in a choice: their meters would be one.
      SameAction Name StateName
    | -- | A choice's action outside a choice: its events would stay nowhere.
      StaysOutside Place
    deriving stock (Eq, Show)

{- | A whole flow starts from one type and ends in one, so it has one in port
and one end. Its graph holds only the states a run can reach: a branch an
injection never takes (@inl :> (f ||| g)@ never runs @g@) is not drawn.
-}
graph :: (NotSum i, NotSum o) => Flow i e o -> Either Clash OpenGraph
graph flow = whole =<< part flow

whole :: (NotSum i, NotSum o) => Part i o -> Either Clash OpenGraph
whole p = do
    inPort <- entryOf p
    let edges = fmap (fmap node) p.edges
        reached = reachable inPort edges
        g =
            OpenGraph
                { inPort
                , edges = Map.filterWithKey (\(from, _) _ -> Set.member from reached) edges
                , loops = Map.mapMaybe (\at -> if Set.member at.entry reached then Just at {body = Set.intersection at.body reached} else Nothing) p.loops
                , caps = Map.filterWithKey (\metered _ -> Set.member metered.place reached) p.caps
                , routes = Set.intersection p.routes reached
                }
    case [metered.place | (metered, cap) <- Map.toList g.caps, refuses cap.atCap, null (leaving g metered.place)] of
        [] -> pure g
        place : _ -> Left (RefuseWithoutWayOut place)
  where
    refuses = \case
        Refuse -> True
        Stop -> False
        Extend -> False
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
summand of its out, as an injection or 'Id' does.
-}
data Entry o = Enters Place | Passes (Sel o)

-- | The graph of a term inside a flow: one in port per summand of @i@, out edges typed by summand of @o@.
data Part i o = Part
    { inPorts :: Sel i -> Entry o
    , edges :: Map (Place, EventName) (Edge (To o))
    , loops :: Map Name LoopAt
    , fans :: Set Name
    -- ^ The fan-outs drawn: each once, as a run keeps one fan-out's tasks per name.
    , caps :: Map Metered Cap
    , routes :: Set Place
    }

part :: Flow i e o -> Either Clash (Part i o)
part = \case
    Do s -> stepPart s
    Capped limit atCap s -> cappedPart limit atCap s
    Id -> Right (passing id)
    f :> g -> do
        left <- part f
        right <- part g
        glue left right
    Loop name body -> closeLoop name =<< part body
    Opt name skips body -> skippable name skips =<< part body
    Par fan body -> Right (fanOut fan body)
    InL -> Right (passing SL)
    InR -> Right (passing SR)
    f :||| g -> do
        left <- part f
        right <- part g
        copair left right
    Catch body -> caught <$> part body
    Scope name body -> inScope name <$> part body
    Choice name branches -> choicePart name branches
    Route name branches -> routePart name branches

{- | Series: each of the left part's out edges goes on to the in port of the
right part's summand it names, and the two exits become one. The paths of
each side get their own prefix, so no state of one side is a state of the
other, and only a loop or fan-out name can clash.
-}
glue :: Part a b -> Part b c -> Either Clash (Part a c)
glue left right = do
    loops <- unionLoops first.loops second.loops
    fans <- unionFans first.fans second.fans
    pure
        Part
            { inPorts = \sel -> case first.inPorts sel of
                Enters place -> Enters place
                Passes on -> second.inPorts on
            , edges = Map.union (fmap (fmap into) first.edges) second.edges
            , loops
            , fans
            , caps = Map.union first.caps second.caps
            , routes = Set.union first.routes second.routes
            }
  where
    first = within 0 left
    second = within 1 right
    into = \case
        ToOut sel -> entering (second.inPorts sel)
        ToState place -> ToState place
        ToExit -> ToExit

-- | Where an edge into this in port goes: the state it enters, or on to the out.
entering :: Entry o -> To o
entering = \case
    Enters place -> ToState place
    Passes sel -> ToOut sel

-- | Case: the left part takes the left summand's in ports, the right part the right's.
copair :: Part a c -> Part b c -> Either Clash (Part (a ':+ b) c)
copair left right = do
    loops <- unionLoops first.loops second.loops
    fans <- unionFans first.fans second.fans
    pure
        Part
            { inPorts = \case
                SL sel -> first.inPorts sel
                SR sel -> second.inPorts sel
            , edges = Map.union first.edges second.edges
            , loops
            , fans
            , caps = Map.union first.caps second.caps
            , routes = Set.union first.routes second.routes
            }
  where
    first = within 0 left
    second = within 1 right

-- | An injection or 'Id': no state, each summand of its in passes on to its summand of the out.
passing :: (Sel i -> Sel o) -> Part i o
passing inject = Part {inPorts = Passes . inject, edges = Map.empty, loops = Map.empty, fans = Set.empty, caps = Map.empty, routes = Set.empty}

-- | The codiagonal: the body's exit edges go on as its out.
caught :: (NotSum b) => Part a b -> Part a b
caught body = Part {inPorts = body.inPorts, edges = fmap out body.edges, loops = body.loops, fans = body.fans, caps = body.caps, routes = body.routes}
  where
    out edge = case edge.to of
        ToExit -> edge {to = ToOut Here}
        ToOut sel -> edge {to = ToOut sel}
        ToState place -> edge {to = ToState place}

{- | Every name inside the part prefixed with the scope's: its states, their
events, its loops, skips and fan-outs.
-}
inScope :: Name -> Part i o -> Part i o
inScope scope p =
    Part
        { inPorts = moved.inPorts
        , edges = Map.fromList [((from, eventIn event), edgeIn edge) | ((from, event), edge) <- Map.toList moved.edges]
        , loops = Map.mapKeys (scoped scope) moved.loops
        , fans = Set.map (scoped scope) p.fans
        , caps = moved.caps
        , routes = moved.routes
        }
  where
    moved = movePlaces (\place -> place {scope = scopePath scope <> place.scope}) p
    eventIn = qualifyEvent (scopePath scope)
    edgeIn edge =
        Edge
            { to = edge.to
            , arrow = case edge.arrow of
                Along along -> Along along {event = eventIn along.event}
                Skip name skips -> Skip (scoped scope name) skips
                Stay -> Stay
            , back = scoped scope <$> edge.back
            }

{- | One state, one edge per outcome: an exit to the exit, a continuing one to
the out, or to its summand of the out when the step branches.
-}
stepPart :: forall k (s :: k) i e o. (StepSet k, Sig s ~ '(i, e, o), KnownTy i, KnownTy o, NotSum i) => Sing s -> Either Clash (Part i o)
stepPart s = do
    edges <- case outcomes s of
        Continues continue -> Right [edge continue (ToOut Here) (tyVal @o)]
        exits@(ExitsOr exit continue) -> Right [edge exit ToExit (exitTy exits), edge continue (ToOut Here) (tyVal @o)]
        branches@(Branches left right) ->
            let (leftTy, rightTy) = summandTys branches
             in Right [edge left (ToOut (SL Here)) leftTy, edge right (ToOut (SR Here)) rightTy]
        OpensChildren -> Left (StaysOutside place)
        AsksOnly -> Left (StaysOutside place)
    Right
        Part
            { inPorts = \Here -> Enters place
            , edges = Map.fromList edges
            , loops = Map.empty
            , fans = Set.empty
            , caps = Map.empty
            , routes = Set.empty
            }
  where
    place = rootPlace (stepName s)
    edge :: OutcomeName -> To o -> Ty -> ((Place, EventName), Edge (To o))
    edge outcome to cod =
        let event = EventName place.name outcome
         in ((place, event), Edge to (Along (OutcomeEdge event (tyVal @i) cod)) Nothing)

-- | A part's own state, before gluing moves it or a scope names it.
rootPlace :: StateName -> Place
rootPlace = Place [] mempty

-- | 'stepPart' with the step's meter capped at its state.
cappedPart :: (StepSet k, Meter s, Sig s ~ '(i, e, o), KnownTy i, KnownTy o, NotSum i) => PerFuel Limit -> AtCap -> Sing (s :: k) -> Either Clash (Part i o)
cappedPart limit atCap s = do
    p <- stepPart s
    Right Part {inPorts = p.inPorts, edges = p.edges, loops = p.loops, fans = p.fans, caps = Map.singleton (Metered (rootPlace (stepName s)) (stepName s)) (Cap (SomeMeter s) limit atCap 0), routes = p.routes}

{- | One state, the hub: each action's events stay there, each action's
meter is spent there, and @enough@ goes on to the out. The hub is a loop of
its own, its body the hub alone, so its meters last while the run stays and
start afresh each time it comes back (law Kleene star). Branches are a set:
the drawing names each by its step, and its position is only its cap's
rank, the order it is shown in.
-}
choicePart :: forall a. (KnownTy a, NotSum a) => Name -> [Flow a 'Nothing a] -> Either Clash (Part a a)
choicePart name branches = do
    actions <- traverse (uncurry action) (zip [0 ..] branches)
    edges <- foldM (\drawn (key, edge) -> insertNew key edge drawn) (Map.singleton (hub, enough) leave) (concatMap fst actions)
    caps <- foldM capOnce Map.empty (map snd actions)
    Right Part {inPorts = \Here -> Enters hub, edges, loops = Map.singleton name LoopAt {entry = hub, body = Set.singleton hub}, fans = Set.empty, caps, routes = Set.empty}
  where
    hub = rootPlace (namedState name)
    enough = EventName hub.name enoughOutcome
    leave = Edge (ToOut Here) (Along (OutcomeEdge enough (tyVal @a) (tyVal @a))) Nothing
    stays :: (StepSet k) => Sing (s :: k) -> OutcomeName -> ((Place, EventName), Edge (To a))
    stays s outcome = ((hub, EventName (stepName s) outcome), Edge (ToState hub) Stay Nothing)
    action :: Int -> Flow a 'Nothing a -> Either Clash ([((Place, EventName), Edge (To a))], (Metered, Cap))
    action rank = \case
        Capped limit atCap s ->
            let metered = (Metered hub (stepName s), Cap (SomeMeter s) limit atCap rank)
             in case outcomes s of
                    OpensChildren -> Right ([stays s spawnedOutcome, stays s handedBackOutcome], metered)
                    AsksOnly -> Right ([], metered)
                    Continues _ -> Left (NotAnAction name)
        Do _ -> notAction
        Id -> notAction
        _ :> _ -> notAction
        Loop _ _ -> notAction
        Opt {} -> notAction
        Par _ _ -> notAction
        -- InL, InR and :||| are absent: a sum in or out, which a branch's type refutes.
        Catch _ -> notAction
        Scope _ _ -> notAction
        Choice _ _ -> notAction
        Route _ _ -> notAction
    notAction = Left (NotAnAction name)
    capOnce drawn (metered, cap)
        | Map.member metered drawn = Left (SameAction name metered.step)
        | otherwise = Right (Map.insert metered cap drawn)

{- | One state, the hub: one edge per branch, @<route>.<branch>@, into that
branch's in port, each branch's states beside the others' as a case's are.
The hub is no loop: the run picks once ('Route').
-}
routePart :: forall a e c. (KnownTy a, NotSum a) => Name -> NonEmpty (OutcomeName, Flow a e c) -> Either Clash (Part a c)
routePart name branches = do
    drawn <- traverse (\(i, (branch, f)) -> (branch,) . within i <$> part f) (zip [0 ..] (toList branches))
    let parts = map snd drawn
    edges <- foldM (\inserted (key, edge) -> insertNew key edge inserted) (Map.unions (map (.edges) parts)) (map (uncurry pick) drawn)
    loops <- foldM unionLoops Map.empty (map (.loops) parts)
    fans <- foldM unionFans Set.empty (map (.fans) parts)
    Right Part {inPorts = \Here -> Enters hub, edges, loops, fans, caps = Map.unions (map (.caps) parts), routes = Set.insert hub (Set.unions (map (.routes) parts))}
  where
    hub = rootPlace (namedState name)
    pick branch p =
        let event = EventName hub.name branch
         in ((hub, event), Edge (entering (p.inPorts Here)) (Along (OutcomeEdge event (tyVal @a) (tyVal @a))) Nothing)

exitTy :: forall x o. Outcomes ('Just x) o -> Ty
exitTy (ExitsOr _ _) = tyVal @x

summandTys :: forall a b. Outcomes 'Nothing (a ':+ b) -> (Ty, Ty)
summandTys (Branches _ _) = (tyVal @a, tyVal @b)

{- | The body's continue goes back to its in port; its exit is the loop's
out. A body that caps no step outside its nested loops is refused: a nested
loop's caps start afresh each time the run enters it, so they bound nothing here.
-}
closeLoop :: (NotSum a, NotSum b) => Name -> Part a a -> Either Clash (Part a b)
closeLoop name body = do
    entry <- entryOf body
    loops <- unionLoops body.loops (Map.singleton name LoopAt {entry, body = sources body.edges})
    let nested = foldMap (.body) body.loops
        closed edge = case edge.to of
            ToOut _ -> Edge (ToState entry) edge.arrow (Just name)
            ToExit -> Edge (ToOut Here) edge.arrow edge.back
            ToState place -> Edge (ToState place) edge.arrow edge.back
    if any ((`Set.notMember` nested) . (.place)) (Map.keys body.caps)
        then pure Part {inPorts = \Here -> Enters entry, edges = fmap closed body.edges, loops, fans = body.fans, caps = body.caps, routes = body.routes}
        else Left (Unbounded name)

{- | A skip edge from the body's in port to its out, named after its first
state. A body that runs no step is the identity already: it has nothing to skip.
-}
skippable :: (NotSum a) => Name -> PerFuel SkipWhen -> Part a a -> Either Clash (Part a a)
skippable name skips body = case body.inPorts Here of
    Passes _ -> Right body
    Enters entry -> do
        edges <- insertNew (entry, EventName entry.name skippedOutcome) (Edge (ToOut Here) (Skip name skips) Nothing) body.edges
        pure Part {inPorts = body.inPorts, edges, loops = body.loops, fans = body.fans, caps = body.caps, routes = body.routes}

-- | The state a part over one type starts at, if it runs a step before it ends.
entryOf :: (NotSum a) => Part a o -> Either Clash Place
entryOf p = case p.inPorts Here of
    Enters place -> Right place
    Passes _ -> Left NoStep

{- | One state: each child runs the body as a run of its own, so the body is
not drawn here and gives only its types. Children are spawned and hand back
while the state stays; @done@ leaves it, once every task is settled
("State.Run.Fan"). The parent logs the stay events under the bare names
@spawned@ and @handed_back@: they carry the child, not an outcome.
-}
fanOut :: forall a b. (KnownTy a, KnownTy b) => Name -> Flow a 'Nothing b -> Part ('List a) ('List b)
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
        , fans = Set.singleton fan
        , caps = Map.empty
        , routes = Set.empty
        }
  where
    place = rootPlace (namedState fan)
    edge event target = ((place, fanEvent event place.name), target)

-- | The graph's states. Every state has an edge out, so the edges' keys hold them all.
places :: OpenGraph -> Set Place
places g = sources g.edges

{- | The innermost loop whose body holds the state: the smallest, as a
nested loop's body is inside its enclosing loop's.
-}
innermost :: OpenGraph -> Place -> Maybe LoopAt
innermost g place = case [loop | loop <- Map.elems g.loops, Set.member place loop.body] of
    [] -> Nothing
    loop : others -> Just (minimumBy (comparing (Set.size . (.body))) (loop :| others))

-- | The edges out of the state that leave the innermost loop around it: every one, for a state in no loop.
leaving :: OpenGraph -> Place -> [(EventName, Edge Node)]
leaving g place = [(event, edge) | ((from, event), edge) <- Map.toList g.edges, from == place, not (stays edge.to)]
  where
    stays = \case
        At to -> maybe False (Set.member to . (.body)) (innermost g place)
        Out -> False
        Exit -> False

{- | An event as drawn beside the state it leaves: its outcome, or the
whole event where another step's event stays there, as a choice's actions' do.
-}
eventLabel :: Place -> EventName -> Text
eventLabel place event@(EventName step (OutcomeName outcome))
    | step == placeName place = outcome
    | otherwise = eventText event

{- | Whether the run sits at a 'Route''s hub, where it picks a branch, and
where nothing of a branch has run yet.
-}
isRouteHub :: OpenGraph -> Node -> Bool
isRouteHub g = \case
    At place -> Set.member place g.routes
    Out -> False
    Exit -> False

-- | The states these edges leave.
sources :: Map (Place, EventName) a -> Set Place
sources edges = Set.fromList (map fst (Map.keys edges))

-- | Prefixes every path, so the part can sit beside another.
within :: Int -> Part i o -> Part i o
within branch = movePlaces (\place -> place {path = branch : place.path})

-- | Every state of the part moved: where its in ports enter, its edges leave and go, and its loops and caps sit.
movePlaces :: (Place -> Place) -> Part i o -> Part i o
movePlaces move p =
    Part
        { inPorts = \sel -> case p.inPorts sel of
            Enters place -> Enters (move place)
            Passes on -> Passes on
        , edges = Map.fromList [((move from, event), fmap node edge) | ((from, event), edge) <- Map.toList p.edges]
        , loops = fmap (\at -> at {entry = move at.entry, body = Set.map move at.body}) p.loops
        , fans = p.fans
        , caps = Map.mapKeys (\metered -> metered {place = move metered.place}) p.caps
        , routes = Set.map move p.routes
        }
  where
    node = \case
        ToState place -> ToState (move place)
        ToOut sel -> ToOut sel
        ToExit -> ToExit

unionLoops :: Map Name LoopAt -> Map Name LoopAt -> Either Clash (Map Name LoopAt)
unionLoops left right = case Map.keys (Map.intersection left right) of
    [] -> Right (Map.union left right)
    name : _ -> Left (SameLoop name)

unionFans :: Set Name -> Set Name -> Either Clash (Set Name)
unionFans left right = case Set.toList (Set.intersection left right) of
    [] -> Right (Set.union left right)
    fan : _ -> Left (SameFan fan)

insertNew :: (Place, EventName) -> Edge n -> Map (Place, EventName) (Edge n) -> Either Clash (Map (Place, EventName) (Edge n))
insertNew key@(place, event) edge = Map.alterF (maybe (Right (Just edge)) (const (Left (SameEvent place event)))) key
