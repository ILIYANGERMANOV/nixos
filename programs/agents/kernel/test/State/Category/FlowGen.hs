-- | Generators of well-typed flow terms and of walks through their graphs.
module State.Category.FlowGen (
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
    pathTo,
    skipsKept,
    composes,
    redrawn,
    threeWay,
    threeWayGraph,
    genBranches,
) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Typeable (Typeable)
import Hedgehog (Gen)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import State.Category.Flow (Branch (..), Branches (..), Cappable (..), Flow (..), Group (..), Name (..), ScopePath, scopePath)
import Data.Text qualified as Text
import State.Category.Fuel (PerFuel (..), SkipWhen (..), always)
import State.Category.Graph (Edge (..), LoopAt (..), Metered (..), Node (..), OpenGraph (..), Place (..), graph, places)
import State.Category.Graph qualified as Graph
import State.Category.Meter (AtCap (..), Limit (..))
import State.Category.Step (EventName, OutcomeEdge (..), OutcomeName (..), StateName)
import State.Category.Ty (KnownTy, NotSum, TyOf (..))
import State.Flow.Library (choice, gather, opt, par)
import State.Flow.Triage (Sing (..))
import State.Step.Build (Sing (..))
import State.Step.Fan (Sing (..), engineers)
import State.Step.Plan (Sing (..))
import State.Step.Review (Sing (..))
import State.Step.Ship (Sing (..))

{- | The steps of one type that a generated flow chains, with and without an
exit. Each exiting one caps a step, so a loop over it is bounded.
-}
data Kit a = Kit {endo :: [Flow a 'Nothing a], exiting :: [Flow a ('Just a) a]}

-- | A gather's choice is @Ctx@'s only step: no step of its own exits.
ctxKit :: Kit 'Ctx
ctxKit = Kit [gather] []

planKit :: Kit 'Plan
planKit = Kit [Do SimplifyP, Do Draft] []

-- | A review with rows always fixes them before the diff goes on.
diffKit :: Kit 'Diff
diffKit = Kit [Do Refactor] [Do Review :> Capped (always (UpTo 3)) Refuse (Step PickRows) :> Do Fix, Do ReReview :> Capped (UpTo <$> PerFuel 1 3 5) Refuse (Step PickRows) :> Do Fix]

prKit :: Kit 'PR
prKit = Kit [Do SimplifyPR, Do FixPR] [Do AwaitCi :> Capped (always (UpTo 5)) Stop (Step FixPR)]

-- | A term from @Ctx@ to @PR@ through every type, any combinator on each.
genFlow :: Gen (Flow 'Ctx 'Nothing 'PR)
genFlow = do
    ctx <- genEndo ctxKit
    plan <- genEndo planKit
    Gen.choice
        [ (\diff pr -> ctx :> Do PlanS :> plan :> Do Implement :> diff :> Do Describe :> pr) <$> genEndo diffKit <*> genEndo prKit
        , pure (Loop "round" (ctx :> Do PlanS :> plan :> Do (Breakdown engineers) :> Par engineers engineer :> Capped (always (UpTo 9)) Stop (Step (Merge engineers))))
        , pure (Loop "round" (ctx :> Do PlanS :> plan :> Do (Breakdown engineers) :> par (Group "engineers") engineer :> Capped (always (UpTo 9)) Stop (Step (Merge engineers))))
        ]
  where
    engineer = Do PlanS :> Do Implement :> Do Describe

{- | A term from @Diff@ to @PR@ that branches: a triage whose two branches go
on, or a pick of one of two.
-}
genBranching :: Gen (Flow 'Diff 'Nothing 'PR)
genBranching =
    Gen.recursive
        Gen.choice
        [inFresh (pure (Do Describe))]
        [ (:>) <$> genEndo diffKit <*> genBranching
        , inFresh ((\small big -> Do Triage :> Case (#small :-> small :& #big :-> Do Implement :> big :& End)) <$> genBranching <*> genBranching)
        , inFresh ((\name f g -> choice name (#small :-> f :& #big :-> g :& End)) <$> genName <*> genBranching <*> genBranching)
        , inFresh (Route <$> genName <*> genBranches genBranching)
        ]

{- | A route from a diff to its PR over three branches, each entering a
state of its own: @describe@, @big/refactor@ and @other/describe@. A
branch that draws a step another branch draws is scoped, as a flow names
each state once.
-}
threeWay :: Flow 'Diff 'Nothing 'PR
threeWay = Route "route" ((OutcomeName "small", Do Describe) :| [(OutcomeName "big", Scope "big" (Do Refactor :> Do Describe)), (OutcomeName "other", Scope "other" (Do Describe :> Do FixPR))])

-- | 'threeWay''s graph.
threeWayGraph :: OpenGraph
threeWayGraph = either (error . show) id (graph threeWay)

-- | A route's branches, one to three, each under a name of its own.
genBranches :: Gen (Flow a e c) -> Gen (NonEmpty (OutcomeName, Flow a e c))
genBranches gen = NonEmpty.zip (OutcomeName "small" :| [OutcomeName "big", OutcomeName "other"]) <$> Gen.nonEmpty (Range.linear 1 3) gen

genEndo :: (KnownTy a, NotSum a, Typeable a) => Kit a -> Gen (Flow a 'Nothing a)
genEndo kit =
    Gen.recursive
        Gen.choice
        [inFresh (Gen.element kit.endo)]
        ( [ inFresh (opt <$> genName <*> genSkips <*> genEndo kit)
          , (:>) <$> genEndo kit <*> genEndo kit
          , Scope <$> genName <*> genEndo kit
          , inFresh (Route <$> genName <*> genBranches (genEndo kit))
          ]
            <> [inFresh (Loop <$> genName <*> genExiting kit) | not (null kit.exiting)]
        )

-- | A loop or skip name from a small pool, so nested terms sometimes reuse one.
genName :: Gen Name
genName = Gen.element ["gather", "plan", "review", "ci", "round"]

{- | The term under a scope of its own: a flow names each state once, and
two terms drawn alike would draw one state twice. Never shrunk, so a shrink
never makes two scopes one.
-}
inFresh :: Gen (Flow a e b) -> Gen (Flow a e b)
inFresh gen = Scope <$> Gen.prune (Name . ("t" <>) . Text.pack . show <$> Gen.int (Range.constant 0 (999999 :: Int))) <*> gen

-- | The root or a nesting of up to three scopes from 'genName''s pool.
genScopePath :: Gen ScopePath
genScopePath = foldMap scopePath <$> Gen.list (Range.linear 0 3) genName

genSkips :: Gen (PerFuel SkipWhen)
genSkips = PerFuel <$> skip <*> skip <*> skip
  where
    skip = Gen.element [Never, AtOrBelow 100, Skippable]

-- | A term with an exit, an exiting step glued on either side of an endo term.
genExiting :: (KnownTy a, NotSum a, Typeable a) => Kit a -> Gen (Flow a ('Just a) a)
genExiting kit =
    Gen.choice
        [ (:>) <$> inFresh (Gen.element kit.exiting) <*> genEndo kit
        , (:>) <$> genEndo kit <*> inFresh (Gen.element kit.exiting)
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
    go n place = case [(event, next) | ((from, event), Edge {to = At next}) <- Map.toList g.edges, from == place] of
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
            let next = [(edge.to, event : walked) | ((place, event), edge) <- Map.toList g.edges, At place == node, edge.to `Set.notMember` seen]
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
        , routes = Set.map ranked g.routes
        , groupStates = Map.mapKeys ranked g.groupStates
        }
  where
    ranks = Map.fromList (zip (Set.toList (places g)) [0 ..])
    ranked place = place {path = [Map.findWithDefault (-1) place ranks]}
    node = \case
        At place -> At (ranked place)
        Out -> Out
        Graph.Exit -> Graph.Exit
