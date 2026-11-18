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
    GroupAt (..),
    GroupOf (..),
    eachDoneOutcome,
    shownOrder,
    Clash (..),
    graph,
    places,
    innermost,
    leaving,
    outOf,
    eventLabel,
) where

import Data.Foldable (minimumBy)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Ord (comparing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)

-- Flow's 'Exit' is qualified: 'Exit' here is the 'Node'.
import State.Category.Flow (AgentRole, Branch (..), Branches (..), CapTarget (..), FanEvent (..), Flow (Await, Capped, Case, Catch, Do, Each, Fork, Id, Into, Loop, Scope, (:>)), Group (..), Name (..), ScopePath, fanEvent, nameText, namedState, qualify, qualifyEvent, scopePath, scoped)
import State.Category.Flow qualified as Flow
import State.Category.Fuel (PerFuel)
import State.Category.Meter (AtCap (..), Limit, Meter, SomeMeter (..))
import State.Category.Step (EventName (..), OutcomeEdge (..), OutcomeName (..), Outcomes (..), Sig, Sing, StateName (..), StepSet, eventText, outcomes, stepName)
import State.Category.Ty (Elem (..), IsSum, KnownTy (..), NotSum, Summand (..), Summands (..), Ty, TyOf (..), TyVal, elemLabel)

{- | A state where a step, a fork or an await runs next. The path is the step's
position in the term, so a step used twice is two states. The name is its
step's, or its group's, inside the scopes around it: 'placeName' is what
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
    | -- | A child spawned or handed back at an await, the identity.
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
state, presentation only: 0, as a state meters only its own step.
-}
data Cap = Cap {meter :: SomeMeter, limit :: PerFuel Limit, atCap :: AtCap, rank :: Int}
    deriving stock (Eq, Show)

-- | Where a 'Capped' step's budget is spent: at its own state.
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
    , groupStates :: Map Place GroupAt
    -- ^ The 'Fork' and 'Await' states, by group in its scopes.
    }
    deriving stock (Eq, Show)

data Clash
    = -- | Two edges leave one state on one event.
      SameEvent Place EventName
    | -- | One loop name twice: its rounds would mix.
      SameLoop Name
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
    | -- | A step that only forks ('State.Category.Step.OpensChildren') drawn by 'Do', not 'Fork': it would never leave its state.
      StaysOutside Place
    | {- | A 'Fork' with a way out of the flow, by its end or its exit,
      that passes no 'Await' of its group: its children would outlive it.
      -}
      NotAwaited Place Name
    | -- | Two states of one name: an event names its state, so one would stand for both.
      SameState StateName
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
                , groupStates = Map.restrictKeys p.groups reached
                }
    case [name | (name, n) <- Map.toList (Map.fromListWith (+) [(placeName place, 1 :: Int) | place <- Set.toList reached]), n > 1] of
        [] -> pure ()
        name : _ -> Left (SameState name)
    case [metered.place | (metered, cap) <- Map.toList g.caps, refuses cap.atCap, null (leaving g metered.place)] of
        [] -> pure ()
        place : _ -> Left (RefuseWithoutWayOut place)
    case [(place, group) | (place, Forking group) <- Map.toList p.groups, Set.member place reached, escapes g.edges (awaitsOf group) place] of
        [] -> pure g
        (place, group) : _ -> Left (NotAwaited place group.group)
  where
    awaitsOf group = Map.keysSet (Map.filter (== Awaiting group) p.groups)
    refuses = \case
        Refuse -> True
        Stop -> False
        Extend -> False
    node = \case
        ToState place -> At place
        ToOut _ -> Out
        ToExit -> Exit

{- | Whether a walk from this state reaches the flow's end or exit without
passing one of these states: they do not post-dominate it.
-}
escapes :: Map (Place, EventName) (Edge Node) -> Set Place -> Place -> Bool
escapes edges awaits start = any leavesFlow (Map.toList walked)
  where
    walked = Map.filterWithKey (\(from, _) _ -> Set.notMember from awaits) edges
    reached = reachable start walked
    leavesFlow ((from, _), edge) =
        Set.member from reached && case edge.to of
            At _ -> False
            Out -> True
            Exit -> True

-- | The states a walk from this one can reach.
reachable :: Place -> Map (Place, EventName) (Edge Node) -> Set Place
reachable start edges = go Set.empty [start]
  where
    go seen = \case
        [] -> seen
        place : rest
            | Set.member place seen -> go seen rest
            | otherwise -> go (Set.insert place seen) ([next | (_, Edge {to = At next}) <- outOf place edges] <> rest)

{- | Which summand of @t@ an edge continues into, down to one type. 'Here' at
a sum does not type-check, so every selector names one in port. Its context
is the equality, not 'NotSum': building a 'Here' from a 'NotSum' given then
forces that evidence, so a refusal deferred to run time fires when drawn.
-}
data Sel (t :: Ty) where
    Here :: (IsSum t ~ 'False) => Sel t
    In :: (IsSum a ~ 'False) => Elem ss l a -> Sel ('Sum ss)

-- | Where an edge of a part goes: a state, a summand of the part's out, or its exit.
data To o = ToState Place | ToOut (Sel o) | ToExit

{- | Where a summand of a part's in enters: a state, straight on to a
summand of its out, as 'Id' does, or out by the exit, as 'Exit' does.
-}
data Entry o = Enters Place | Passes (Sel o) | Exits

-- | The graph of a term inside a flow: one in port per summand of @i@, out edges typed by summand of @o@.
data Part i o = Part
    { inPorts :: Sel i -> Entry o
    , edges :: Map (Place, EventName) (Edge (To o))
    , loops :: Map Name LoopAt
    , caps :: Map Metered Cap
    , groups :: Map Place GroupAt
    -- ^ The 'Fork' and 'Await' states, by group: 'whole' checks each fork is awaited.
    }

-- | What a state does to its group's children: starts one, or waits for all.
data GroupAt = Forking GroupOf | Awaiting GroupOf
    deriving stock (Eq, Show)

-- | A group in its scopes, and the role that runs each of its children ('Group').
data GroupOf = GroupOf {group :: Name, runner :: AgentRole}
    deriving stock (Eq, Show)

part :: Flow i e o -> Either Clash (Part i o)
part = \case
    Do s -> stepPart s
    Capped limit atCap (Step s) -> cappedPart limit atCap s
    Capped limit atCap (ForkOf (Group group runner) s) -> Right (cappedFork limit atCap (GroupOf group runner) s)
    Id -> Right (passing Passes)
    Into -> Right (passing (\Here -> Passes Here))
    f :> g -> do
        left <- part f
        right <- part g
        glue left right
    Loop name body -> closeLoop name =<< part body
    Case branches -> casePart 0 branches
    Flow.Exit -> Right (passing (const Exits))
    Each body -> eachPart =<< part body
    Fork (Group group runner) body -> Right (forkPart (GroupOf group runner) (forkName group body))
    Await (Group group runner) -> Right (awaitPart (GroupOf group runner))
    Catch body -> caught <$> part body
    Scope name body -> inScope name <$> part body

{- | Series: each of the left part's out edges goes on to the in port of the
right part's summand it names, and the two exits become one. The paths of
each side get their own prefix, so no state of one side is a state of the
other, and only a loop name can clash.
-}
glue :: Part a b -> Part b c -> Either Clash (Part a c)
glue left right = do
    loops <- unionLoops first.loops second.loops
    pure
        Part
            { inPorts = \sel -> case first.inPorts sel of
                Enters place -> Enters place
                Passes on -> second.inPorts on
                Exits -> Exits
            , edges = Map.union (fmap (fmap into) first.edges) second.edges
            , loops
            , caps = Map.union first.caps second.caps
            , groups = Map.union first.groups second.groups
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
    Exits -> ToExit

{- | Case: each summand's in port is its branch's, the branches beside each
other, the @n@th under path prefix @n@.
-}
casePart :: Int -> Branches ss e c -> Either Clash (Part ('Sum ss) c)
casePart n = \case
    End -> Right (passing (\(In e) -> case e of {}))
    (_ :-> f) :& rest -> do
        first <- within n <$> part f
        others <- casePart (n + 1) rest
        loops <- unionLoops first.loops others.loops
        pure
            Part
                { inPorts = \(In e) -> case e of
                    First -> first.inPorts Here
                    Next e' -> others.inPorts (In e')
                , edges = Map.union first.edges others.edges
                , loops
                , caps = Map.union first.caps others.caps
                , groups = Map.union first.groups others.groups
                }

-- | 'Id', 'Into' or 'Exit': no state, each summand of its in passes on to where it enters.
passing :: (Sel i -> Entry o) -> Part i o
passing inPorts = Part {inPorts, edges = Map.empty, loops = Map.empty, caps = Map.empty, groups = Map.empty}

-- | The codiagonal: the body's exit edges, and an in port straight to its exit, go on as its out.
caught :: (NotSum b) => Part a b -> Part a b
caught body = body {inPorts = inPort, edges = fmap out body.edges}
  where
    inPort sel = case body.inPorts sel of
        Exits -> Passes Here
        entry -> entry
    out edge = case edge.to of
        ToExit -> edge {to = ToOut Here}
        ToOut sel -> edge {to = ToOut sel}
        ToState place -> edge {to = ToState place}

{- | Every name inside the part prefixed with the scope's: its states, their
events, its loops, skips and groups.
-}
inScope :: Name -> Part i o -> Part i o
inScope scope p =
    Part
        { inPorts = moved.inPorts
        , edges = Map.fromList [((from, eventIn event), edgeIn edge) | ((from, event), edge) <- Map.toList moved.edges]
        , loops = Map.mapKeys (scoped scope) moved.loops
        , caps = moved.caps
        , groups = fmap groupIn moved.groups
        }
  where
    groupIn = \case
        Forking group -> Forking group {group = scoped scope group.group}
        Awaiting group -> Awaiting group {group = scoped scope group.group}
    moved = movePlaces (\place -> place {scope = scopePath scope <> place.scope}) p
    eventIn = qualifyEvent (scopePath scope)
    edgeIn edge =
        Edge
            { to = edge.to
            , arrow = case edge.arrow of
                Along along -> Along along {event = eventIn along.event}
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
        branches@Branches -> Right (branchEdges branches)
        OpensChildren -> Left (StaysOutside place)
    Right (oneState place (Map.fromList edges))
  where
    place = rootPlace (stepName s)
    branchEdges :: forall ss. (o ~ 'Sum ss) => Outcomes 'Nothing ('Sum ss) -> [((Place, EventName), Edge (To o))]
    branchEdges Branches = [edge (OutcomeName (elemLabel e)) (ToOut (In e)) (summandTy e) | Summand e <- summands @ss]
    edge :: OutcomeName -> To o -> TyVal -> ((Place, EventName), Edge (To o))
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
    Right Part {inPorts = p.inPorts, edges = p.edges, loops = p.loops, caps = Map.singleton (Metered (rootPlace (stepName s)) (stepName s)) (Cap (SomeMeter s) limit atCap 0), groups = p.groups}

exitTy :: forall x o. Outcomes ('Just x) o -> TyVal
exitTy (ExitsOr _ _) = tyVal @x

summandTy :: forall ss l a. (KnownTy a) => Elem ss l a -> TyVal
summandTy _ = tyVal @a

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
        then pure body {inPorts = \Here -> Enters entry, edges = fmap closed body.edges, loops}
        else Left (Unbounded name)

-- | The state a part over one type starts at, if it runs a step before it ends.
entryOf :: (NotSum a) => Part a o -> Either Clash Place
entryOf p = case p.inPorts Here of
    Enters place -> Right place
    Passes _ -> Left NoStep
    Exits -> Left NoStep

{- | The body's states once: its out goes back to its first state for the
next item, and @<first>.each_done@ leaves once the items are spent. A body
that runs no step maps each item straight on.
-}
eachPart :: forall a b. (KnownTy a, KnownTy b, NotSum a, NotSum b) => Part a b -> Either Clash (Part ('List a) ('List b))
eachPart body = case body.inPorts Here of
    Passes Here -> Right (passing (\Here -> Passes Here))
    Exits -> Right (passing (\Here -> Exits))
    Enters entry -> do
        let next edge = case edge.to of
                ToOut Here -> edge {to = ToState entry}
                ToState place -> edge {to = ToState place}
                ToExit -> edge {to = ToExit}
            event = EventName entry.name eachDoneOutcome
        edges <- insertNew (entry, event) (Edge (ToOut Here) (Along (OutcomeEdge event (List (tyVal @a)) (List (tyVal @b)))) Nothing) (fmap next body.edges)
        pure body {inPorts = \Here -> Enters entry, edges}

-- | The outcome that leaves an 'Each' once its items are spent.
eachDoneOutcome :: OutcomeName
eachDoneOutcome = OutcomeName "each_done"

{- | One state: @spawned@ starts a child in the group and goes on with the
input. The child's body is its own run, so only its types are drawn here.
-}
forkPart :: forall a. (KnownTy a, NotSum a) => GroupOf -> StateName -> Part a a
forkPart group name =
    (oneState place (Map.singleton (place, event) (Edge (ToOut Here) (Along (OutcomeEdge event (tyVal @a) (tyVal @a))) Nothing)))
        { groups = Map.singleton place (Forking group)
        }
  where
    place = rootPlace name
    event = fanEvent Spawns name

{- | A 'Fork''s state: its step's, when it forks one step, so the spawn is
that step's @spawned@ outcome; else @spawn_<group>@. The group's own name
is its 'Await''s.
-}
forkName :: Name -> Flow a e b -> StateName
forkName group = \case
    Do s -> stepName s
    Capped {} -> spawnName
    Id -> spawnName
    Into -> spawnName
    _ :> _ -> spawnName
    Loop _ _ -> spawnName
    Case _ -> spawnName
    Flow.Exit -> spawnName
    Each _ -> spawnName
    Fork _ _ -> spawnName
    Await _ -> spawnName
    Catch _ -> spawnName
    Scope _ _ -> spawnName
  where
    spawnName = StateName ("spawn_" <> nameText group)

-- | 'forkPart' of one step, its meter counting the children it starts.
cappedFork :: forall k (s :: k) a. (StepSet k, Meter s, KnownTy a, NotSum a) => PerFuel Limit -> AtCap -> GroupOf -> Sing s -> Part a a
cappedFork limit atCap group s = Part {inPorts = p.inPorts, edges = p.edges, loops = p.loops, caps = Map.singleton (Metered (rootPlace (stepName s)) (stepName s)) (Cap (SomeMeter s) limit atCap 0), groups = p.groups}
  where
    p = forkPart group (stepName s)

{- | One state, the group's: a child's @handed_back@ stays, @done@ goes on
with every child's result once all have handed back.
-}
awaitPart :: forall a b. (KnownTy a, KnownTy b, NotSum a) => GroupOf -> Part a ('List b)
awaitPart group =
    ( oneState
        place
        ( Map.fromList
            [ ((place, fanEvent HandsBack place.name), Edge (ToState place) Stay Nothing)
            , ((place, done), Edge (ToOut Here) (Along (OutcomeEdge done (tyVal @a) (List (tyVal @b)))) Nothing)
            ]
        )
    )
        { groups = Map.singleton place (Awaiting group)
        }
  where
    place = rootPlace (namedState group.group)
    done = fanEvent Leaves place.name

-- | A part of one state: entered there, with these edges out of it.
oneState :: (IsSum i ~ 'False) => Place -> Map (Place, EventName) (Edge (To o)) -> Part i o
oneState place edges = Part {inPorts = \Here -> Enters place, edges, loops = Map.empty, caps = Map.empty, groups = Map.empty}

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
leaving g place = [(event, edge) | (event, edge) <- outOf place g.edges, not (stays edge.to)]
  where
    stays = \case
        At to -> maybe False (Set.member to . (.body)) (innermost g place)
        Out -> False
        Exit -> False

{- | An event as drawn beside the state it leaves: its outcome, or the
whole event where another step's event is taken there.
-}
eventLabel :: Place -> EventName -> Text
eventLabel place event@(EventName step (OutcomeName outcome))
    | step == placeName place = outcome
    | otherwise = eventText event

{- | The edges out of the state, by event: a range of the map, as its keys
order by state first.
-}
outOf :: Place -> Map (Place, EventName) a -> [(EventName, a)]
outOf place = map (\((_, event), a) -> (event, a)) . Map.toAscList . Map.takeWhileAntitone ((== place) . fst) . Map.dropWhileAntitone ((< place) . fst)

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
            Exits -> Exits
        , edges = Map.fromList [((move from, event), fmap node edge) | ((from, event), edge) <- Map.toList p.edges]
        , loops = fmap (\at -> at {entry = move at.entry, body = Set.map move at.body}) p.loops
        , caps = Map.mapKeys (\metered -> metered {place = move metered.place}) p.caps
        , groups = Map.mapKeys move p.groups
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

insertNew :: (Place, EventName) -> Edge n -> Map (Place, EventName) (Edge n) -> Either Clash (Map (Place, EventName) (Edge n))
insertNew key@(place, event) edge = Map.alterF (maybe (Right (Just edge)) (const (Left (SameEvent place event)))) key
