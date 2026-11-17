module State.Category.GraphSpec (spec) where

import Control.Monad (foldM)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Set qualified as Set
import Hedgehog (Gen, PropertyT, forAll, (===))
import Hedgehog.Gen qualified as Gen
import State.Category.Flow (Branch (..), Branches (..), Flow (..), Group (..), branchesWith, qualifyEvent, scopePath)
import State.Category.Flow qualified as Flow
import State.Category.FlowGen (ctxKit, diffKit, genBranching, genEndo, genExiting, genFlow, genWalk, genWalkTo, pathTo, threeWay)
import State.Category.Fuel (always)
import State.Category.Graph (Clash (..), Edge (..), Node (..), OpenGraph (..), Place (..), graph, places)
import State.Category.Graph qualified as Graph
import State.Category.Meter (AtCap (..), Limit (..))
import State.Category.Path (step, ty)
import State.Category.Step (EventName (..), OutcomeName (..), StateName (..), outcomeNames, outcomes)
import State.Category.Ty (NotSum, TyOf (..))
import State.Flow.Library (par)
import State.Flow.Triage (Sing (..))
import State.Run.RunGen qualified as RunGen
import State.Step.Build (Sing (..))
import State.Step.Fan (Sing (..))
import State.Step.Gather (Sing (..))
import State.Step.Plan (Sing (..))
import State.Step.Ship (Sing (..))
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "State.Category.Graph" $ do
    {- The law, read off the graph of @f :> g@ as a run sees it, not by
    gluing again: it holds both sides' edges and loops, a walk through @f@ to
    its end goes on into @g@, typed as the two in turn, and an exit of either
    side is the whole's exit.
    -}
    describe "graph_of_seq_is_glue_of_graphs" $ do
        it "keeps every edge and loop of both sides" . hedgehog $ do
            (left, right, whole) <- seqGraphs (genExiting diffKit) (genExiting diffKit)
            (Map.size whole.edges, Map.size whole.loops) === (Map.size left.edges + Map.size right.edges, Map.size left.loops + Map.size right.loops)

        it "walks the first side to its end, then the second, when neither exits" . hedgehog $ do
            (left, right, whole) <- seqGraphs (genEndo ctxKit) (genEndo ctxKit)
            walkF <- forAll (genWalk left)
            walkG <- forAll (genWalk right)
            (endOf whole (walkF <> walkG), ty whole (walkF <> walkG)) === (Just Out, (<>) <$> ty left walkF <*> ty right walkG)

        it "walks the first side to its end, then the second to its end or exit" . hedgehog $ do
            (left, right, whole) <- seqGraphs (genExiting diffKit) (genExiting diffKit)
            walkF <- forAll (genWalk left)
            port <- forAll (Gen.element [Out, Graph.Exit])
            walkG <- forAll (genWalkTo port right)
            (endOf whole (walkF <> walkG), ty whole (walkF <> walkG)) === (Just port, (<>) <$> ty left walkF <*> ty right walkG)

        it "takes an exit of the first side as the whole's exit" . hedgehog $ do
            (left, _, whole) <- seqGraphs (genExiting diffKit) (genExiting diffKit)
            walkF <- forAll (genWalkTo Graph.Exit left)
            (endOf whole walkF, ty whole walkF) === (Just Graph.Exit, ty left walkF)

    {- A 'Map' keyed by (state, event) holds one target per pair, so the law
    can only break by an edge silently merged into another's key: the graph
    must keep every arrow of the term.
    -}
    it "graph_has_one_target_per_state_event" . hedgehog $ do
        (flow, g) <- forAll (Gen.mapMaybe (\flow -> either (const Nothing) (Just . (flow,)) (graph flow)) genFlow)
        Map.size g.edges === arrows flow

    it "every_state_is_reached_from_the_start_and_reaches_the_end" . hedgehog $ do
        g <- forAll (Gen.mapMaybe (either (const Nothing) Just . graph) genBranching)
        [place | place <- Set.toList (places g), isNothing (pathTo g (At g.inPort) (At place)) || isNothing (pathTo g (At place) Out)] === []

    it "refuses a loop id used twice: their rounds would mix" $
        graph (Loop "ci" (Do AwaitCi :> Loop "ci" (Do AwaitCi :> fixCapped) :> fixCapped))
            `shouldBe` Left (SameLoop "ci")

    it "refuses a loop whose body caps no step: nothing bounds it" $
        graph (Loop "ci" (Do AwaitCi :> Do FixPR))
            `shouldBe` Left (Unbounded "ci")

    it "refuses a loop whose only cap is a nested loop's: it starts afresh each time" $
        graph (Loop "outer" (Do AwaitCi :> Loop "ci" (Do AwaitCi :> fixCapped)))
            `shouldBe` Left (Unbounded "outer")

    it "refuses a Refuse cap on a step whose every outcome stays in its loop: past the cap nothing is left to record" $
        graph (Loop "ci" (Do AwaitCi :> Capped (always (UpTo 5)) Refuse FixPR))
            `shouldBe` Left (RefuseWithoutWayOut (Place [1] mempty (StateName "fix_pr")))

    it "refuses a fan id drawn twice: a run keeps one fan-out's tasks per fan id" $
        graph (Par "engineers" (Do SimplifyPR) :> Par "engineers" (Do SimplifyPR))
            `shouldBe` Left (SameFan "engineers")

    describe "a fork and its await" $ do
        it "refuses a fork no await follows: its children would outlive the flow" $
            graph (Fork engineerGroup engineerChild :> Do PlanS)
                `shouldBe` Left (NotAwaited (Place [0] mempty (StateName "engineers")) "engineers")

        it "refuses a fork whose way out by an exit passes no await" $
            graph (Fork engineerGroup (Do Describe) :> Do Triage :> Case (#small :-> Do Describe :> Flow.Exit :& #big :-> Do Implement :> Await engineerGroup :> Capped (always (UpTo 9)) Stop (Merge "engineers") :& End))
                `shouldBe` Left (NotAwaited (Place [0] mempty (StateName "engineers")) "engineers")

        it "walks par as a spawn per item, the items done, a hand-back per child, then on" $
            (`endOf` map (EventName (StateName "engineers") . OutcomeName) ["spawned", "spawned", "each_done", "handed_back", "handed_back", "done"]) <$> graph (par engineerGroup engineerChild)
                `shouldBe` Right (Just Out)

    describe "a choice" $ do
        it "refuses a branch that is not a capped action: it would leave the choice" $
            graph (Choice "gather" [Do Interview])
                `shouldBe` Left (NotAnAction "gather")

        it "refuses one action twice: their meters would be one" $
            graph (Choice "gather" [questions, questions])
                `shouldBe` Left (SameAction "gather" (StateName "interview"))

        it "refuses an action outside a choice: its events would stay nowhere" $
            graph questions
                `shouldBe` Left (StaysOutside (Place [] mempty (StateName "interview")))

    describe "a route" $ do
        let picks scope = [(qualifyEvent scope (EventName (StateName "route") (OutcomeName branch)), At (Place path scope (StateName entry))) | (branch, path, entry) <- [("big", [1, 0], "refactor"), ("other", [2, 0], "describe"), ("small", [0], "describe")]]
        it "draws one hub, its start, with one edge per branch into that branch's first state" $
            outOfStart <$> graph threeWay `shouldBe` Right (picks mempty)

        it "names its hub and its picks inside a scope" $
            outOfStart <$> graph (Scope "x" threeWay) `shouldBe` Right (picks (scopePath "x"))

        it "is in neither the engineer nor the 10x flow: they run as before the route" $
            map (.routes) [RunGen.g, RunGen.tenXGraph] `shouldBe` [Set.empty, Set.empty]

        it "refuses one branch name twice: a pick would not say which" $
            graph (Route "route" ((OutcomeName "small", Do Describe) :| [(OutcomeName "small", Do Refactor :> Do Describe)]))
                `shouldBe` Left (SameEvent (Place [] mempty (StateName "route")) (EventName (StateName "route") (OutcomeName "small")))

-- | The edges out of the graph's first state: each event and where it goes.
outOfStart :: OpenGraph -> [(EventName, Node)]
outOfStart g = [(event, edge.to) | ((from, event), edge) <- Map.toList g.edges, from == g.inPort]

-- | The gather's questions, capped as an action of its choice.
questions :: Flow 'Ctx 'Nothing 'Ctx
questions = Capped (always (UpTo 3)) Extend Interview

-- | The graphs of two terms and of their series, over terms that build: 'Clash' has its own cases.
seqGraphs :: (NotSum a, NotSum b, NotSum c) => Gen (Flow a e1 b) -> Gen (Flow b e2 c) -> PropertyT IO (OpenGraph, OpenGraph, OpenGraph)
seqGraphs genF genG = forAll (Gen.mapMaybe builds ((,) <$> genF <*> genG))
  where
    builds (f, g) = case (graph f, graph g, graph (f :> g)) of
        (Right left, Right right, Right whole) -> Just (left, right, whole)
        _ -> Nothing

-- | Where the events walk from the in port.
endOf :: OpenGraph -> [EventName] -> Maybe Node
endOf g = foldM next (At g.inPort)
  where
    next node event = case node of
        At place -> (.to) <$> step g place event
        Out -> Nothing
        Graph.Exit -> Nothing

-- | One per outcome of each step, one per skip, a fan-out's three events, and one per route's branch.
arrows :: Flow i e o -> Int
arrows = \case
    Do s -> length (outcomeNames (outcomes s))
    Capped _ _ s -> length (outcomeNames (outcomes s))
    f :> g -> arrows f + arrows g
    Id -> 0
    Into -> 0
    Loop _ body -> arrows body
    Par _ _ -> 3
    Case branches -> sum (branchesWith arrows branches)
    Flow.Exit -> 0
    Each body -> 1 + arrows body
    Fork _ _ -> 1
    Await _ -> 2
    Catch body -> arrows body
    Scope _ body -> arrows body
    Choice _ branches -> 1 + sum (map arrows branches)
    Route _ branches -> sum (fmap ((1 +) . arrows . snd) branches)

-- | The 10x's engineers, each a child run from a task's context to its PR.
engineerGroup :: Group 'PR
engineerGroup = Group "engineers"

engineerChild :: Flow 'Ctx 'Nothing 'PR
engineerChild = Do PlanS :> Do Implement :> Do Describe

-- | A fix of a red CI, capped as the ship flow caps it.
fixCapped :: Flow 'PR 'Nothing 'PR
fixCapped = Capped (always (UpTo 5)) Stop FixPR
