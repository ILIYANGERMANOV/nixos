-- | Generators of well-typed flow terms and of walks through their graphs.
module State.FlowGen (
    Kit (..),
    ctxKit,
    diffKit,
    genEndo,
    genExiting,
    genFlow,
    genWalk,
    genWalkTo,
    pathTo,
    bypasses,
    composes,
) where

import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Hedgehog (Gen)
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import State.Cap (EventName, OutcomeEdge (..), StateName, Step (..), Ty (..))
import State.Flow (FanId (..), Flow (..), OnEmpty (..))
import State.Graph (Arrow (..), Edge (..), Node (..), OpenGraph (..), Place (..))
import State.Mode (Cfg (..), Mode, SkipWhen (..), cfg)

-- | The steps of one type that a generated flow chains, with and without an exit.
data Kit a = Kit {endo :: [Flow a 'Nothing a], exiting :: [Flow a ('Just a) a]}

ctxKit :: Kit 'Ctx
ctxKit = Kit [Do Research] [Do Interview]

planKit :: Kit 'Plan
planKit = Kit [Do SimplifyP, Do Alternative, Do Draft] []

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

genEndo :: Kit a -> Gen (Flow a 'Nothing a)
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
genExiting :: Kit a -> Gen (Flow a ('Just a) a)
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
