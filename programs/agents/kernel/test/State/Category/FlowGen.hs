-- | Generators of well-typed flow terms and of walks through their graphs.
module State.Category.FlowGen (
    Kit (..),
    ctxKit,
    diffKit,
    genEndo,
    genExiting,
    genFlow,
    genBranching,
    genWalk,
    genWalkTo,
    pathTo,
    skipsKept,
    composes,
) where

import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Hedgehog (Gen)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import State.Category.Flow (FanId (..), Flow (..), OnEmpty (..), inl, inr, (|||))
import State.Category.Graph (Arrow (..), Edge (..), Node (..), OpenGraph (..), Place (..))
import State.Category.Mode (Cfg (..), Mode, SkipWhen (..), cfg, modes)
import State.Category.Step (EventName, OutcomeEdge (..), StateName)
import State.Category.Ty (NotSum, Ty (..))
import State.Flow.Triage (Sing (..))
import State.Step.Build (Sing (..))
import State.Step.Fan (Sing (..))
import State.Step.Gather (Sing (..))
import State.Step.Plan (Sing (..))
import State.Step.Review (Sing (..))
import State.Step.Ship (Sing (..))

-- | The steps of one type that a generated flow chains, with and without an exit.
data Kit a = Kit {endo :: [Flow a 'Nothing a], exiting :: [Flow a ('Just a) a]}

ctxKit :: Kit 'Ctx
ctxKit = Kit [Do Research] [Do Interview]

planKit :: Kit 'Plan
planKit = Kit [Do SimplifyP, Do Draft] []

diffKit :: Kit 'Diff
diffKit = Kit [Do Refactor, Do Fix] [Do Review, Do Pick]

prKit :: Kit 'PR
prKit = Kit [Do SimplifyPR, Do FixPR, Do Ready] [Do AwaitCi]

-- | A term from @Ctx@ to @PR@ through every type, any combinator on each.
genFlow :: Gen (Flow 'Ctx 'Nothing 'PR)
genFlow = do
    ctx <- genEndo ctxKit
    plan <- genEndo planKit
    rest <-
        Gen.choice
            [ (\diff pr -> Do Implement :> diff :> Do Describe :> pr) <$> genEndo diffKit <*> genEndo prKit
            , pure (Do Breakdown :> Par FEngineers (Do PlanS :> Do Implement :> Do Describe) :> Do Merge)
            ]
    pure (ctx :> Do PlanS :> plan :> rest)

{- | A term from @Diff@ to @PR@ that branches: a triage whose two branches go
on, or an injection into a case, whose other branch no run takes.
-}
genBranching :: Gen (Flow 'Diff 'Nothing 'PR)
genBranching =
    Gen.recursive
        Gen.choice
        [pure (Do Describe)]
        [ (:>) <$> genEndo diffKit <*> genBranching
        , (\small big -> Do Triage :> (small ||| Do Implement :> big)) <$> genBranching <*> genBranching
        , (\f g -> inl :> (f ||| g)) <$> genBranching <*> genBranching
        , (\f g -> inr :> (f ||| g)) <$> genBranching <*> genBranching
        ]

genEndo :: (NotSum a) => Kit a -> Gen (Flow a 'Nothing a)
genEndo kit =
    Gen.recursive
        Gen.choice
        [Gen.element kit.endo]
        ( [ Opt <$> Gen.enumBounded <*> genEndo kit
          , (:>) <$> genEndo kit <*> genEndo kit
          ]
            <> [Loop <$> Gen.enumBounded <*> Gen.element [StopOut, ExitOut] <*> genExiting kit | not (null kit.exiting)]
        )

-- | A term with an exit, an exiting step glued on either side of an endo term.
genExiting :: (NotSum a) => Kit a -> Gen (Flow a ('Just a) a)
genExiting kit =
    Gen.choice
        [ (:>) <$> Gen.element kit.exiting <*> genEndo kit
        , (:>) <$> genEndo kit <*> Gen.element kit.exiting
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

{- | Each mode and kept state where that mode bypasses the state: none, by
#351's Keep law. A flow whose graph does not build skips them all.
-}
skipsKept :: Either e OpenGraph -> [StateName] -> [(Mode, StateName)]
skipsKept built kept = [(mode, name) | mode <- modes, name <- kept, either (const True) (\g -> bypasses mode g name) built]

{- | A run in this mode can reach the end without running a step of this
name: it takes a skip, which leaves the skipped step's state, only where the
mode may skip.
-}
bypasses :: Mode -> OpenGraph -> StateName -> Bool
bypasses mode g name = isJust (pathTo g {edges = Map.filterWithKey taken g.edges} (At g.inPort) Out)
  where
    taken (from, _) edge = case edge.arrow of
        Skip optId -> (cfg mode).skip optId /= Never
        Along _ -> from.name /= name
        Stay -> from.name /= name

-- | Each edge starts where the one before it ends: a path of @Cap@.
composes :: [OutcomeEdge] -> Bool
composes edges = and (zipWith (\a b -> a.cod == b.dom) edges (drop 1 edges))
