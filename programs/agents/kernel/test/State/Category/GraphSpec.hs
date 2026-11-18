module State.Category.GraphSpec (spec) where

import Control.Monad (foldM, void)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Set qualified as Set
import Hedgehog (Gen, PropertyT, forAll, (===))
import Hedgehog.Gen qualified as Gen
import State.Category.Flow (AgentRole (..), Branch (..), Branches (..), CapTarget (..), Flow (..), Group (..), Shape (..), branchesWith, qualifyEvent, scopePath)
import State.Category.Flow qualified as Flow
import State.Category.FlowGen (AnyFlow (..), ctxKit, diffKit, genBranching, genEndo, genExiting, genFlow, genWalk, genWalkTo, pathTo, threeWay)
import State.Category.Fuel (always)
import State.Category.Graph (Clash (..), Edge (..), Node (..), OpenGraph (..), Place (..), graph, outOf, places)
import State.Category.Graph qualified as Graph
import State.Category.Meter (AtCap (..), Limit (..))
import State.Category.Path (step, ty)
import State.Category.Step (EventName (..), OutcomeName (..), StateName (..), outcomeNames, outcomes)
import State.Category.Ty (NotSum, TyOf (..))
import State.Flow.Library (choiceLoop, parallel)
import State.Flow.Triage (Sing (..))
import State.Step.Build (BuildStep (..), Sing (..))
import State.Step.Fan (Sing (..))
import State.Step.Gather (GatherStep (..), Sing (..))
import State.Step.Plan (PlanStep (..), Sing (..))
import State.Step.Ship (ShipStep (..), Sing (..))
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
        (AnyFlow flow, g) <- forAll (Gen.mapMaybe (\any'@(AnyFlow flow) -> either (const Nothing) (Just . (any',)) (graph flow)) genFlow)
        Map.size g.edges === arrows flow

    it "every_state_is_reached_from_the_start_and_reaches_the_end" . hedgehog $ do
        g <- forAll (Gen.mapMaybe (\(AnyFlow flow) -> either (const Nothing) Just (graph flow)) genBranching)
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
        graph (Loop "ci" (Do AwaitCi :> Capped (always (UpTo 5)) Refuse (Step FixPR)))
            `shouldBe` Left (RefuseWithoutWayOut (Place [1] mempty (StateName "fix_pr")))

    describe "a fork and its await" $ do
        it "refuses a fork no await follows: its children would outlive the flow" $
            graph (Fork engineerGroup engineerChild :> Do PlanS)
                `shouldBe` Left (NotAwaited (Place [0] mempty (StateName "spawn_engineers")) "engineers")

        it "refuses a fork whose way out by an exit passes no await" $
            graph (Fork engineerGroup (Do Refactor :> Do Describe) :> Do Triage :> Case (#small :-> Do Describe :> Flow.Exit :& #big :-> Do Implement :> Await engineerGroup :> Capped (always (UpTo 9)) Stop (Step (Merge "engineers")) :& End))
                `shouldBe` Left (NotAwaited (Place [0] mempty (StateName "spawn_engineers")) "engineers")

        -- parallel's fork, then its await: each its own state.
        let forked = map (EventName (StateName "spawn_engineers") . OutcomeName)
            awaited = map (EventName (StateName "engineers") . OutcomeName)

        it "walks parallel as a spawn per item, the items done, a hand-back per child, then on" $
            (`endOf` (forked ["spawned", "spawned", "each_done"] <> awaited ["handed_back", "handed_back", "done"])) <$> graph (parallel engineerGroup engineerChild)
                `shouldBe` Right (Just Out)

        it "draws a fork of one step as that step's state, its spawn the step's own outcome" $
            outOfStart <$> graph (researchers :> Await researcherGroup)
                `shouldBe` Right [(EventName (StateName "research") (OutcomeName "spawned"), At (Place [1] mempty (StateName "researchers")))]

        it "refuses two states of one name: an event names its state, so one would stand for both" $
            [void (graph (Do Describe :> Do FixPR :> Do FixPR)), void (graph (Do Describe :> Do FixPR :> Scope "x" (Do FixPR)))]
                `shouldBe` [Left (SameState (StateName "fix_pr")), Right ()]

    describe "a choice" $ do
        it "refuses one capped action under two labels of a choice loop: one state would stand for both" $
            graph (choiceLoop "gather" Id (#ask :-> questions :& #again :-> questions :& End))
                `shouldBe` Left (SameState (StateName "interview"))

    describe "a choice's pick" $ do
        let picks scope = [(qualifyEvent scope (EventName (StateName "route") (OutcomeName branch)), At (Place path (scope <> inner) (StateName entry))) | (branch, path, inner, entry) <- [("big", [1, 1, 0], scopePath "big", "refactor"), ("other", [1, 2, 0], scopePath "other", "describe"), ("small", [1, 0], mempty, "describe")]]
        it "draws one pick, its start, with one edge per branch into that branch's first state" $
            outOfStart <$> graph threeWay `shouldBe` Right (picks mempty)

        it "names its pick and its events inside a scope" $
            outOfStart <$> graph (Scope "x" threeWay) `shouldBe` Right (picks (scopePath "x"))

-- | The edges out of the graph's first state: each event and where it goes.
outOfStart :: OpenGraph -> [(EventName, Node)]
outOfStart g = [(event, edge.to) | (event, edge) <- outOf g.inPort g.edges]

-- | The gather's questions, capped as an action of its choice.
questions :: Flow (CappedS (DoS Interview)) 'Ctx 'Nothing 'Ctx
questions = Capped (always (UpTo 3)) Extend (Step Interview)

-- | The graphs of two terms and of their series, over terms that build: 'Clash' has its own cases.
seqGraphs :: (NotSum a, NotSum b, NotSum c) => Gen (AnyFlow a e1 b) -> Gen (AnyFlow b e2 c) -> PropertyT IO (OpenGraph, OpenGraph, OpenGraph)
seqGraphs genF genG = forAll (Gen.mapMaybe builds ((,) <$> genF <*> genG))
  where
    builds (AnyFlow f, AnyFlow g) = case (graph f, graph g, graph (f :> g)) of
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

-- | One per outcome of each step, a fork's spawn, an each's done and an await's two events.
arrows :: Flow s i e o -> Int
arrows = \case
    Do s -> length (outcomeNames (outcomes s))
    Capped _ _ (Step s) -> length (outcomeNames (outcomes s))
    Capped _ _ (ForkOf _ _) -> 1
    f :> g -> arrows f + arrows g
    Id -> 0
    Into -> 0
    Loop _ body -> arrows body
    Case branches -> sum (branchesWith arrows branches)
    Flow.Exit -> 0
    Each body -> 1 + arrows body
    Fork _ _ -> 1
    Await _ -> 2
    Catch body -> arrows body
    Scope _ body -> arrows body
    Handle _ body -> arrows body

-- | The 10x's engineers, each a child run from a task's context to its PR.
engineerGroup :: Group 'PR
engineerGroup = Group "engineers" (AgentRole "engineer")

-- | Researchers forked one at a time, three at most: a fork of one step.
researchers :: Flow (CappedS (ForkS (DoS Research))) 'Ctx 'Nothing 'Ctx
researchers = Capped (always (UpTo 3)) Extend (ForkOf researcherGroup Research)

researcherGroup :: Group 'Ctx
researcherGroup = Group "researchers" (AgentRole "researcher")

engineerChild :: Flow (DoS PlanS :>> DoS Implement :>> DoS Describe) 'Ctx 'Nothing 'PR
engineerChild = Do PlanS :> Do Implement :> Do Describe

-- | A fix of a red CI, capped as the ship flow caps it.
fixCapped :: Flow (CappedS (DoS FixPR)) 'PR 'Nothing 'PR
fixCapped = Capped (always (UpTo 5)) Stop (Step FixPR)
