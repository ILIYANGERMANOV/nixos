module State.Category.GraphSpec (spec) where

import Control.Monad (foldM)
import Data.Either (isRight)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Set qualified as Set
import Hedgehog (Gen, PropertyT, forAll, (===))
import Hedgehog.Gen qualified as Gen
import State.Category.Flow (Flow (..), LoopId (..), OnEmpty (..), OptId (..), inl, inr, (|||))
import State.Category.FlowGen (ctxKit, diffKit, genBranching, genEndo, genExiting, genFlow, genWalk, genWalkTo, pathTo)
import State.Category.Graph (Clash (..), Edge (..), LoopAt (..), Node (..), OpenGraph (..), Place (..), graph, places)
import State.Category.Path (step, ty)
import State.Category.Step (EventName (..), OutcomeName (..), StateName (..), outcomeNames, outcomes)
import State.Category.Ty (NotSum, Ty (..))
import State.Flow.Triage (Sing (..))
import State.Step.Build (Sing (..))
import State.Step.Gather (Sing (..))
import State.Step.Review (Sing (..))
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
            port <- forAll (Gen.element [Out, Exit])
            walkG <- forAll (genWalkTo port right)
            (endOf whole (walkF <> walkG), ty whole (walkF <> walkG)) === (Just port, (<>) <$> ty left walkF <*> ty right walkG)

        it "takes an exit of the first side as the whole's exit" . hedgehog $ do
            (left, _, whole) <- seqGraphs (genExiting diffKit) (genExiting diffKit)
            walkF <- forAll (genWalkTo Exit left)
            (endOf whole walkF, ty whole walkF) === (Just Exit, ty left walkF)

    {- A 'Map' keyed by (state, event) holds one target per pair, so the law
    can only break by an edge silently merged into another's key: the graph
    must keep every arrow of the term.
    -}
    it "graph_has_one_target_per_state_event" . hedgehog $ do
        (flow, g) <- forAll (Gen.mapMaybe (\flow -> either (const Nothing) (Just . (flow,)) (graph flow)) genFlow)
        Map.size g.edges === arrows flow

    {- The laws of the sum in #351, read off the graph a run walks: a case
    after an injection is the branch it injects into, and the case is
    associative.
    -}
    describe "sums" $ do
        it "inl_then_case_draws_as_the_left_branch" . hedgehog $ do
            (f, g) <- forAll genCase
            fmap redrawn (graph (inl :> (f ||| g))) === fmap redrawn (graph f)

        it "inr_then_case_draws_as_the_right_branch" . hedgehog $ do
            (f, g) <- forAll genCase
            fmap redrawn (graph (inr :> (f ||| g))) === fmap redrawn (graph g)

        {- @x@ ends in @(Diff + Plan) + Plan@; the associator moves it to
        @Diff + (Plan + Plan)@, so both cases see the same three branches.
        -}
        it "case_is_associative" . hedgehog $ do
            (f, g, h) <- forAll ((,,) <$> genBranching <*> genPlanned <*> genPlanned)
            let x = Do Triage :> (Do Triage :> inl ||| inr)
                associator = (inl ||| inl :> inr) ||| inr :> inr
            fmap redrawn (graph (x :> ((f ||| g) ||| h))) === fmap redrawn (graph (x :> associator :> (f ||| (g ||| h))))

        it "every_state_is_reached_from_the_start_and_reaches_the_end" . hedgehog $ do
            g <- forAll (Gen.mapMaybe (either (const Nothing) Just . graph) genBranching)
            [place | place <- Set.toList (places g), isNothing (pathTo g (At g.inPort) (At place)) || isNothing (pathTo g (At place) Out)] === []

    it "refuses a loop id used twice: their rounds would mix" $
        graph (Loop LReview ExitOut (Do Review :> Loop LReview ExitOut (Do Pick :> Do Fix)))
            `shouldBe` Left (SameLoop LReview)

    it "refuses two skips of one state: a log could not say which was skipped" $
        graph (Opt ORes (Opt OSimp (Do Research)))
            `shouldBe` Left (SameEvent (Place [] (StateName "research")) (EventName (StateName "research") (OutcomeName "skipped")))

-- | The graphs of two terms and of their series, over terms that build: 'Clash' has its own cases.
seqGraphs :: (NotSum a, NotSum b, NotSum c) => Gen (Flow a e1 b) -> Gen (Flow b e2 c) -> PropertyT IO (OpenGraph, OpenGraph, OpenGraph)
seqGraphs genF genG = forAll (Gen.mapMaybe builds ((,) <$> genF <*> genG))
  where
    builds (f, g) = case (graph f, graph g, graph (f :> g)) of
        (Right left, Right right, Right whole) -> Just (left, right, whole)
        _ -> Nothing

{- | Two branches whose case builds. A clash inside either branch, or a loop
id both use, refuses the whole term, even the branch an injection never
runs: 'Clash' has its own cases.
-}
genCase :: Gen (Flow 'Diff 'Nothing 'PR, Flow 'Diff 'Nothing 'PR)
genCase = Gen.filter builds ((,) <$> genBranching <*> genBranching)
  where
    builds (f, g) = isRight (graph (inl :> (f ||| g)))

-- | A branch for a planned summand: implement the plan, then on as a diff.
genPlanned :: Gen (Flow 'Plan 'Nothing 'PR)
genPlanned = (Do Implement :>) <$> genBranching

-- | Where the events walk from the in port.
endOf :: OpenGraph -> [EventName] -> Maybe Node
endOf g = foldM next (At g.inPort)
  where
    next node event = case node of
        At place -> (.to) <$> step g place event
        Out -> Nothing
        Exit -> Nothing

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
        }
  where
    ranks = Map.fromList (zip (Set.toList (places g)) [0 ..])
    ranked place = place {path = [Map.findWithDefault (-1) place ranks]}
    node = \case
        At place -> At (ranked place)
        Out -> Out
        Exit -> Exit

-- | One per outcome of each step, one per skip, and a fan-out's three events.
arrows :: Flow i e o -> Int
arrows = \case
    Do s -> length (outcomeNames (outcomes s))
    f :> g -> arrows f + arrows g
    Loop _ _ body -> arrows body
    Opt _ body -> 1 + arrows body
    Par _ _ -> 3
    InL -> 0
    InR -> 0
    f :||| g -> arrows f + arrows g
