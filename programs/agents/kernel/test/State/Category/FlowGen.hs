-- | Generators of well-typed flow terms and of walks through their graphs.
module State.Category.FlowGen (
    AnyFlow (..),
    Kit (..),
    ctxKit,
    diffKit,
    prKit,
    genEndo,
    genExiting,
    genFlow,
    genBranching,
    genWalk,
    genWalkTo,
    genScopePath,
    series,
    pathTo,
    skipsKept,
    composes,
    redrawn,
    threeWay,
    threeWayGraph,
    threeWayPick,
) where

import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Typeable (Typeable)
import Hedgehog (Gen)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import State.Category.Flow (AgentRole (..), Branch (..), Branches (..), CapTarget (..), Flow (..), Group (..), Join, Name (..), ScopePath, Shape (..), scopePath)
import State.Category.Fuel (PerFuel (..), SkipWhen (..), always)
import State.Category.Graph (Edge (..), LoopAt (..), Metered (..), Node (..), OpenGraph (..), Place (..), graph, outOf, places)
import State.Category.Graph qualified as Graph
import State.Category.Meter (AtCap (..), Limit (..))
import State.Category.Step (EventName (..), OutcomeEdge (..), OutcomeName (..), StateName)
import State.Category.Ty (KnownTy, NotSum, TyOf (..))
import State.Flow.Library (ChoiceS, choice, gather, opt, par)
import State.Flow.Triage (Sing (..))
import State.Step.Build (BuildStep (..), Sing (..))
import State.Step.Catalog (AnyOutcome (..), Layer (PickLayer), outcomeEvent)
import State.Step.Fan (Sing (..), engineers)
import State.Step.Pick (Sing (Pick), pickOutcomes)
import State.Step.Plan (Sing (..))
import State.Step.Review (Sing (..))
import State.Step.Ship (ShipStep (..), Sing (..))

{- | A term of any structure: a generated term's 'Shape' is only known
once it is drawn, so a generator hides it.
-}
data AnyFlow i e o where
    AnyFlow :: Flow s i e o -> AnyFlow i e o

deriving stock instance Show (AnyFlow i e o)

-- | The series of two terms of any structure.
series :: AnyFlow a e1 b -> AnyFlow b e2 c -> AnyFlow a (Join e1 e2) c
series (AnyFlow f) (AnyFlow g) = AnyFlow (f :> g)

{- | The steps of one type that a generated flow chains, with and without an
exit. Each exiting one caps a step, so a loop over it is bounded.
-}
data Kit a = Kit {endo :: [AnyFlow a 'Nothing a], exiting :: [AnyFlow a ('Just a) a]}

-- | A gather's choice is @Ctx@'s only step: no step of its own exits.
ctxKit :: Kit 'Ctx
ctxKit = Kit [AnyFlow gather] []

planKit :: Kit 'Plan
planKit = Kit [AnyFlow (Do SimplifyP), AnyFlow (Do Draft)] []

-- | A review with rows always fixes them before the diff goes on.
diffKit :: Kit 'Diff
diffKit = Kit [AnyFlow (Do Refactor)] [AnyFlow (Do Review :> Capped (always (UpTo 3)) Refuse (Step PickRows) :> Do Fix), AnyFlow (Do ReReview :> Capped (UpTo <$> PerFuel 1 3 5) Refuse (Step PickRows) :> Do Fix)]

prKit :: Kit 'PR
prKit = Kit [AnyFlow (Do SimplifyPR), AnyFlow (Do FixPR)] [AnyFlow (Do AwaitCi :> Capped (always (UpTo 5)) Stop (Step FixPR))]

-- | A term from @Ctx@ to @PR@ through every type, any combinator on each.
genFlow :: Gen (AnyFlow 'Ctx 'Nothing 'PR)
genFlow = do
    AnyFlow ctx <- genEndo ctxKit
    AnyFlow plan <- genEndo planKit
    Gen.choice
        [ (\(AnyFlow diff) (AnyFlow pr) -> AnyFlow (ctx :> Do PlanS :> plan :> Do Implement :> diff :> Do Describe :> pr)) <$> genEndo diffKit <*> genEndo prKit
        , pure (AnyFlow (Loop "round" (ctx :> Do PlanS :> plan :> Do (Breakdown engineers) :> par (Group "engineers" (AgentRole "engineer")) engineer :> Capped (always (UpTo 9)) Stop (Step (Merge engineers)))))
        ]
  where
    engineer = Do PlanS :> Do Implement :> Do Describe

{- | A term from @Diff@ to @PR@ that branches: a triage whose two branches go
on, or a pick of one of two.
-}
genBranching :: Gen (AnyFlow 'Diff 'Nothing 'PR)
genBranching =
    bounded $
        Gen.recursive
            Gen.choice
            [inFresh (pure (AnyFlow (Do Describe)))]
            [ series <$> genEndo diffKit <*> genBranching
            , inFresh ((\(AnyFlow small) (AnyFlow big) -> AnyFlow (Do Triage :> Case (#small :-> small :& #big :-> Do Implement :> big :& End))) <$> genBranching <*> genBranching)
            , inFresh ((\name (AnyFlow f) (AnyFlow g) -> AnyFlow (choice name (#small :-> f :& #big :-> g :& End))) <$> genName <*> genBranching <*> genBranching)
            ]

{- | A choice from a diff to its PR over three branches, each entering a
state of its own: @describe@, @big/refactor@ and @other/describe@. A
branch that draws a step another branch draws is scoped, as a flow names
each state once.
-}
threeWay :: Flow (ChoiceS 'Diff ThreeWay '[DoS Describe, ScopeS (DoS Refactor :>> DoS Describe), ScopeS (DoS Describe :>> DoS FixPR)]) 'Diff 'Nothing 'PR
threeWay = choice "route" (#small :-> Do Describe :& #big :-> Scope "big" (Do Refactor :> Do Describe) :& #other :-> Scope "other" (Do Describe :> Do FixPR) :& End)

-- | The labels 'threeWay' picks from.
type ThreeWay = '[ '("small", 'Diff), '("big", 'Diff), '("other", 'Diff)]

-- | 'threeWay''s pick of the branch of this label.
threeWayPick :: OutcomeName -> AnyOutcome
threeWayPick label = case [picked | some <- pickOutcomes (Pick @'Diff @ThreeWay "route"), let picked = AnyOutcome PickLayer some, (outcomeEvent picked).outcome == label] of
    picked : _ -> picked
    [] -> error ("threeWay has no branch " <> show label)

-- | 'threeWay''s graph.
threeWayGraph :: OpenGraph
threeWayGraph = either (error . show) id (graph threeWay)

genEndo :: (KnownTy a, NotSum a, Typeable a) => Kit a -> Gen (AnyFlow a 'Nothing a)
genEndo kit =
    bounded $
        Gen.recursive
            Gen.choice
            [inFresh (Gen.element kit.endo)]
            ( [ inFresh ((\name skips (AnyFlow f) -> AnyFlow (opt name skips f)) <$> genName <*> genSkips <*> genEndo kit)
              , series <$> genEndo kit <*> genEndo kit
              , scope <$> genName <*> genEndo kit
              , inFresh ((\name (AnyFlow f) (AnyFlow g) -> AnyFlow (choice name (#small :-> f :& #big :-> g :& End))) <$> genName <*> genEndo kit <*> genEndo kit)
              ]
                <> [inFresh ((\name (AnyFlow f) -> AnyFlow (Loop name f)) <$> genName <*> genExiting kit) | not (null kit.exiting)]
            )

{- | A term's size at most 20 of hedgehog's 100: every leaf sits under a scope
of its own ('inFresh'), so nearly every term builds, and at full size its
graph runs to hundreds of edges with no case reached that a smaller one
misses. A recursive call is already within the bound, so bounding it again
changes nothing.
-}
bounded :: Gen a -> Gen a
bounded = Gen.scale (min 20)

-- | A loop or skip name from a small pool, so nested terms sometimes reuse one.
genName :: Gen Name
genName = Gen.element ["gather", "plan", "review", "ci", "round"]

{- | The term under a scope of its own: a flow names each state once, and
two terms drawn alike would draw one state twice. Never shrunk, so a shrink
never makes two scopes one.
-}
inFresh :: Gen (AnyFlow a e b) -> Gen (AnyFlow a e b)
inFresh gen = scope <$> Gen.prune (Name . ("t" <>) . Text.pack . show <$> Gen.int (Range.constant 0 (999999 :: Int))) <*> gen

scope :: Name -> AnyFlow a e b -> AnyFlow a e b
scope name (AnyFlow f) = AnyFlow (Scope name f)

-- | The root or a nesting of up to three scopes from 'genName''s pool.
genScopePath :: Gen ScopePath
genScopePath = foldMap scopePath <$> Gen.list (Range.linear 0 3) genName

genSkips :: Gen (PerFuel SkipWhen)
genSkips = PerFuel <$> skip <*> skip <*> skip
  where
    skip = Gen.element [Never, AtOrBelow 100, Skippable]

-- | A term with an exit, an exiting step glued on either side of an endo term.
genExiting :: (KnownTy a, NotSum a, Typeable a) => Kit a -> Gen (AnyFlow a ('Just a) a)
genExiting kit =
    Gen.choice
        [ series <$> inFresh (Gen.element kit.exiting) <*> genEndo kit
        , series <$> genEndo kit <*> inFresh (Gen.element kit.exiting)
        ]

-- | A walk from the in port to 'Out'.
genWalk :: OpenGraph -> Gen [EventName]
genWalk = genWalkTo Out

{- | A walk from the in port to this port: a few random events between
states, then the shortest way on. Retried when the detour wandered where the
port is out of reach, as an exit is past a loop that stops when empty.
-}
genWalkTo :: Node -> OpenGraph -> Gen [EventName]
genWalkTo port g = Gen.just $ do
    detour <- Gen.int (Range.linear 0 12)
    go detour g.inPort
  where
    go 0 place = pure (pathTo g (At place) port)
    go n place = case [(event, next) | (event, Edge {to = At next}) <- outOf place g.edges] of
        [] -> pure (pathTo g (At place) port)
        inside -> do
            (event, next) <- Gen.element inside
            fmap (event :) <$> go (n - 1 :: Int) next

-- | The events of a shortest walk between two nodes, breadth first.
pathTo :: OpenGraph -> Node -> Node -> Maybe [EventName]
pathTo g from target = go (Set.singleton from) [(from, [])]
  where
    go _ [] = Nothing
    go seen ((node, walked) : queue)
        | node == target = Just (reverse walked)
        | otherwise =
            let next = [(edge.to, event : walked) | At place <- [node], (event, edge) <- outOf place g.edges, edge.to `Set.notMember` seen]
             in go (foldr (Set.insert . fst) seen next) (queue <> next)

{- | Each kept state a run can bypass: none, by
#351's Keep law. A flow whose graph does not build skips them all.
-}
skipsKept :: Either e OpenGraph -> [StateName] -> [StateName]
skipsKept built kept = [name | name <- kept, either (const True) (`bypasses` name) built]

{- | A run at this level can reach the end without running a step of this
name: it takes a skip, which leaves the skipped step's state.
level may skip.
-}
bypasses :: OpenGraph -> StateName -> Bool
bypasses g name = isJust (pathTo g {edges = Map.filterWithKey (\(from, _) _ -> from.name /= name) g.edges} (At g.inPort) Out)

-- | Each edge starts where the one before it ends: a path of @Cap@.
composes :: [OutcomeEdge] -> Bool
composes edges = and (zipWith (\a b -> a.cod == b.dom) edges (drop 1 edges))

{- | The graph with each state's path replaced by its rank in the term's
order: two terms that draw the same states in the same order, wherever
their subterms sit, compare equal.
-}
redrawn :: OpenGraph -> OpenGraph
redrawn g =
    OpenGraph
        { inPort = ranked g.inPort
        , edges = Map.fromList [((ranked from, event), fmap node edge) | ((from, event), edge) <- Map.toList g.edges]
        , loops = fmap (\at -> at {entry = ranked at.entry, body = Set.map ranked at.body}) g.loops
        , caps = Map.mapKeys (\metered -> metered {place = ranked metered.place}) g.caps
        , groupStates = Map.mapKeys ranked g.groupStates
        }
  where
    ranks = Map.fromList (zip (Set.toList (places g)) [0 ..])
    ranked place = place {path = [Map.findWithDefault (-1) place ranks]}
    node = \case
        At place -> At (ranked place)
        Out -> Out
        Graph.Exit -> Graph.Exit
