{- | The laws "State.Category.Flow"'s Haddock states, read off the graph a run
walks. Equal is graph isomorphism up to where a state sits in the term
('redrawn'); where a law copies a subterm, equal is bisimilar: a run walks
the same names and events from the start on either side, up to renaming:
the copy sits under @Scope "u"@, so a copied loop keeps a name of its own.
-}
module State.Category.LawsSpec (spec) where

import Data.Either (isRight)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Type.Equality ((:~:) (..))
import Data.Typeable (eqT)
import Hedgehog (Gen, forAll, (===))
import Hedgehog.Gen qualified as Gen
import State.Category.Effect (Handler (..))
import State.Category.Flow (AgentRole (..), Branch (..), Branches (..), CapTarget (..), Flow (..), Group (..), Name (..), Shape (..), branchesWith, nameText, qualify, qualifyText, scoped, unqualify)
import State.Category.Flow qualified as Flow
import State.Category.FlowGen (AnyFlow (..), Kit (..), diffKit, genBranching, genEndo, genExiting, genFlow, genScopePath, prKit, redrawn, series)
import State.Category.Fuel (PerFuel (..), SkipWhen, always, monotone, skipsAtMost)
import State.Category.Graph (Arrow (..), Cap (..), Clash, Edge (..), LoopAt (..), Metered (..), Node (..), OpenGraph (..), Place (..), graph, outOf, placeName, places)
import State.Category.Graph qualified as Graph
import State.Category.Meter (AtCap (..), Limit (..), limitAtMost, meterName)
import State.Category.Step (EventName (..), OutcomeEdge (..), OutcomeName (..), Sing, StateName (..), StepSet, stateNameText)
import State.Category.Ty (NotSum, TyOf (..))
import State.Flow.Engineer (engineer)
import State.Flow.Library (choice, choiceLoop, par)
import State.Flow.TenX (tenX)
import State.Flow.Triage (Sing (..), TriageStep (..))
import State.Step.Build (BuildStep (..), Sing (..))
import State.Step.Fuel (FuelStep, Sing (Fuel, Skip))
import State.Step.Ship (ShipStep (..), Sing (..))
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "laws" $ do
    describe "category" $ do
        it "identity_is_a_unit_of_series" . hedgehog $ do
            AnyFlow f <- forAll (Gen.filter builds genFlow)
            (drawn (Id :> f), drawn (f :> Id)) === (drawn f, drawn f)

        it "into_walks_as_identity" . hedgehog $ do
            AnyFlow f <- forAll (Gen.filter builds genFlow)
            drawn (f :> Into) === drawn f

        it "series_is_associative" . hedgehog $ do
            (AnyFlow f, AnyFlow g, AnyFlow h) <- forAll (Gen.filter (\(AnyFlow f, AnyFlow g, AnyFlow h) -> isRight (graph ((f :> g) :> h))) ((,,) <$> genExiting diffKit <*> genEndo diffKit <*> genBranching))
            drawn ((f :> g) :> h) === drawn (f :> (g :> h))

    {- The sum in #351, read off a step into it, as the core has no
    injection: beta, the step's edge into a summand walks as that summand's
    branch; fusion, a series after a case is the case of each branch then
    the series. A choice's branches are a set: their order is the type's only.
    Eta, @h = Case (each l, inj_l :> h)@, is not expressible: the core has
    no injection, and a flow out of a sum is a 'Case' already, as 'Do'
    takes no sum.
    -}
    describe "sums" $ do
        it "case_beta_each_summand_walks_as_its_branch" . hedgehog $ do
            (AnyFlow f, AnyFlow g) <- forAll genCase
            let walked label = case graph (triaged f g) of
                    Right whole | Just (Edge {to = At entry}) <- Map.lookup (whole.inPort, EventName (StateName "triage") (OutcomeName label)) whole.edges -> Right whole {inPort = entry}
                    other -> other
            (bisimilar <$> walked "small" <*> graph f, bisimilar <$> walked "big" <*> graph (Do Implement :> g)) === (Right [], Right [])

        it "case_fusion_series_distributes_into_each_branch" . hedgehog $ do
            (AnyFlow f, AnyFlow g, AnyFlow h) <- forAll (Gen.filter (\(AnyFlow f, AnyFlow g, AnyFlow h) -> isRight (graph (Do Triage :> Case (#small :-> f :& #big :-> Do Implement :> g :& End) :> h))) ((,,) <$> genEndo diffKit <*> genEndo diffKit <*> genBranching))
            (bisimilar <$> graph (Do Triage :> Case (#small :-> f :& #big :-> Do Implement :> g :& End) :> h) <*> graph (Do Triage :> Case (#small :-> f :> h :& #big :-> Do Implement :> g :> Scope copy h :& End))) === Right []

        it "the_order_of_a_choice_s_branches_changes_nothing_a_run_walks" . hedgehog $ do
            (AnyFlow f, AnyFlow g) <- forAll genCase
            (bisimilar <$> graph (choice "route" (#small :-> f :& #big :-> g :& End)) <*> graph (choice "route" (#big :-> g :& #small :-> f :& End))) === Right []

    describe "Catch, the codiagonal" $ do
        it "catch_moves_past_a_side_with_no_exit" . hedgehog $ do
            (AnyFlow f, AnyFlow g) <- forAll ((,) <$> genEndo diffKit <*> genExiting diffKit)
            drawn (Catch (f :> g)) === drawn (f :> Catch g)

        it "catch_distributes_over_a_case" . hedgehog $ do
            (AnyFlow f, AnyFlow g) <- forAll ((,) <$> genExiting diffKit <*> (series (AnyFlow (Do Implement)) <$> genExiting diffKit))
            drawn (Do Triage :> Catch (Case (#small :-> f :& #big :-> g :& End))) === drawn (Do Triage :> Case (#small :-> Catch f :& #big :-> Catch g :& End))

        it "catching_exit_is_identity" . hedgehog $ do
            AnyFlow f <- forAll (Gen.filter builds genFlow)
            drawn (Catch Flow.Exit :> f) === drawn f

    describe "Loop, Elgot's fixpoint" $ do
        {- The unrolled round is a second copy of the body's states, whose
        edges start no round: bisimilar, caps and all, not isomorphic.
        -}
        it "a_loop_walks_as_its_body_unrolled_once" . hedgehog $ do
            AnyFlow body <- forAll (Gen.filter (\(AnyFlow body) -> isRight (graph (Loop "review" body))) genBody)
            let loop = Loop "review" body
            (bisimilar <$> graph loop <*> graph (Catch (Scope copy body :> loop))) === Right []

        it "a_choice_loop_walks_as_its_choice_unrolled_once" . hedgehog $ do
            (AnyFlow f, AnyFlow g) <- forAll genPolishActions
            let body = choice "polish" (#enough :-> Flow.Exit :& #fix :-> fixCapped :> f :& #simplify :-> g :& End)
            (bisimilar <$> graph (choiceLoop "polish" Id (#fix :-> fixCapped :> f :& #simplify :-> g :& End)) <*> graph (Catch (Scope copy body :> Loop "polish" body))) === Right []

    describe "choiceLoop, the Kleene star of a sum" $
        it "the_order_of_the_actions_changes_nothing_a_run_walks" . hedgehog $ do
            (AnyFlow f, AnyFlow g) <- forAll genPolishActions
            (bisimilar <$> graph (choiceLoop "polish" Id (#fix :-> fixCapped :> f :& #simplify :-> g :& End)) <*> graph (choiceLoop "polish" Id (#simplify :-> g :& #fix :-> fixCapped :> f :& End))) === Right []

    {- What a parent's graph says of @traverse@: each child is a run of its
    own, so the parent draws the same states whatever the child, a series of
    steps or none: identity, @par g Id@, and composition, @par g (f :> h)@,
    draw as @par g f@. The results' values never reach the kernel, so
    @par g (f :> h) = par g f :> par g' h@ holds of the children's runs, not
    of a graph; their order, the items', is the run's
    ("State.Protocol.AdviceSpec", par_identity).
    -}
    describe "par, traverse over child runs" $
        it "par_identity_and_composition_draw_one_parent_graph" . hedgehog $ do
            (AnyFlow f, AnyFlow g) <- forAll ((,) <$> genEndo diffKit <*> genEndo diffKit)
            (drawn (par engineers (f :> g)), drawn (par engineers f)) === (drawn (par engineers Id), drawn (par engineers Id))

    describe "Handle" $
        it "a_handler_draws_as_the_flow_it_handles" . hedgehog $ do
            AnyFlow f <- forAll (Gen.filter builds genFlow)
            (drawn (Handle AgentPicks f), drawn (Handle UserAsks f), drawn (Handle FocusHere f)) === (drawn f, drawn f, drawn f)

    describe "Scope" $ do
        it "scope_preserves_the_graph_but_its_names" . hedgehog $ do
            AnyFlow f <- forAll (Gen.filter builds genFlow)
            (unscoped "inner" <$> graph (Scope "inner" f)) === graph f

        -- Of a series that builds: a clash inside the scope is named bare on one side, scoped on the other.
        it "scope_distributes_over_series" . hedgehog $ do
            (AnyFlow f, AnyFlow g) <- forAll (Gen.filter (\(AnyFlow f, AnyFlow g) -> isRight (graph (f :> g))) ((,) <$> genExiting diffKit <*> genBranching))
            drawn (Scope "inner" (f :> g)) === drawn (Scope "inner" f :> Scope "inner" g)

        it "nested_scopes_are_one_scope_of_both_names" . hedgehog $ do
            AnyFlow f <- forAll genFlow
            graph (Scope "outer" (Scope "inner" f)) === graph (Scope (scoped "outer" "inner") f)

        it "unqualify_inverts_qualify_on_a_slash_free_name" . hedgehog $ do
            scope <- forAll genScopePath
            name <- forAll (Gen.element ["review", "review.rows", "engineers_merge.done"])
            unqualify (qualifyText scope name) === (scope, name)

        it "qualify_is_an_action_of_the_scope_monoid" . hedgehog $ do
            (s, t) <- forAll ((,) <$> genScopePath <*> genScopePath)
            qualify (s <> t) (StateName "review") === qualify s (qualify t (StateName "review"))

        it "names_the_states_around_a_scope_as_bare" . hedgehog $ do
            (AnyFlow f, AnyFlow g) <- forAll (Gen.filter (\(AnyFlow f, AnyFlow g) -> isRight (graph (f :> Scope "inner" g))) ((,) <$> genExiting diffKit <*> genBranching))
            (stateNames <$> graph (f :> Scope "inner" g)) === liftA2 (<>) (stateNames <$> graph f) (stateNames <$> graph (Scope "inner" g))

    describe "PerFuel" $
        it "allows each level at least the spends and runs of the level below, in every named flow" $
            [(flow, name) | (flow, budgets) <- [("engineer" :: String, budgetsOf engineer), ("tenX", budgetsOf tenX)], (name, False) <- budgets]
                `shouldBe` []

{- | Two actions on a PR, the first after a capped fix, whose choice loop
builds: a clash inside either refuses the whole term.
-}
genPolishActions :: Gen (AnyFlow 'PR 'Nothing 'PR, AnyFlow 'PR 'Nothing 'PR)
genPolishActions = Gen.filter (\(AnyFlow f, AnyFlow g) -> isRight (graph (choiceLoop "polish" Id (#fix :-> fixCapped :> f :& #simplify :-> g :& End)))) ((,) <$> genEndo prKit <*> genEndo prKit)

-- | A triage, then a case of its two summands.
triaged :: Flow f 'Diff 'Nothing 'PR -> Flow g 'Diff 'Nothing 'PR -> Flow (DoS Triage :>> CaseS '[f, DoS Implement :>> g]) 'Diff 'Nothing 'PR
triaged f g = Do Triage :> Case (#small :-> f :& #big :-> Do Implement :> g :& End)

-- | The group 'par' forks its children into, in the laws.
engineers :: Group 'Diff
engineers = Group "engineers" (AgentRole "engineer")

-- | A capped fix of a PR: what bounds a choice loop over PRs.
fixCapped :: Flow (CappedS (DoS FixPR)) 'PR 'Nothing 'PR
fixCapped = Capped (always (UpTo 5)) Stop (Step FixPR)

-- | The graph with each state's path its rank, or the clash that refuses the term.
drawn :: (NotSum i, NotSum o) => Flow s i e o -> Either Clash OpenGraph
drawn = fmap redrawn . graph

-- | The term's graph builds: no clash refuses it.
builds :: (NotSum i, NotSum o) => AnyFlow i e o -> Bool
builds (AnyFlow f) = isRight (graph f)

{- | Two branches whose case builds. A clash inside either branch, or a loop
id both use, refuses the whole term: 'Clash' has its own cases.
-}
genCase :: Gen (AnyFlow 'Diff 'Nothing 'PR, AnyFlow 'Diff 'Nothing 'PR)
genCase = Gen.filter (\(AnyFlow f, AnyFlow g) -> isRight (graph (triaged f g)) && isRight (graph (choice "route" (#small :-> f :& #big :-> g :& End)))) ((,) <$> genBranching <*> genBranching)

{- | The scope a law's copied subterm sits under: one loop name drawn twice
would mix its rounds ('SameLoop'), so the copy is renamed.
-}
copy :: Name
copy = "u"

-- | A loop body with an exit.
genBody :: Gen (AnyFlow 'Diff ('Just 'Diff) 'Diff)
genBody =
    Gen.choice
        [ genExiting diffKit
        , (\f exit g -> series f (series exit g)) <$> genEndo diffKit <*> Gen.element diffKit.exiting <*> genEndo diffKit
        ]

{- | The pairs of states, one per graph, that a run reaches together from
the in ports but that differ: in name, in the events that leave them, or in
an edge's arrow or kind of target. Empty when the graphs are bisimilar.
Which round an edge starts ('back') and the loops' extents are not compared;
the caps at the two states are. A name under 'copy' compares as its bare name.
-}
bisimilar :: OpenGraph -> OpenGraph -> [(Place, Place)]
bisimilar left right = go Set.empty [(left.inPort, right.inPort)]
  where
    go _ [] = []
    go seen (pair@(p, q) : rest)
        | Set.member pair seen = go seen rest
        | otherwise = case matched p q of
            Nothing -> pair : go (Set.insert pair seen) rest
            Just next -> go (Set.insert pair seen) (next <> rest)
    matched p q
        | uncopied p.name /= uncopied q.name || Map.keys (uncopiedKeys outP) /= Map.keys (uncopiedKeys outQ) || capsAt p left /= capsAt q right = Nothing
        | otherwise = concat <$> sequence (Map.elems (Map.intersectionWith step (uncopiedKeys outP) (uncopiedKeys outQ)))
      where
        outP = leaving left p
        outQ = leaving right q
    step a b
        | renameArrow strip a.arrow /= renameArrow strip b.arrow = Nothing
        | otherwise = case (a.to, b.to) of
            (At x, At y) -> Just [(x, y)]
            (Out, Out) -> Just []
            (Graph.Exit, Graph.Exit) -> Just []
            _ -> Nothing
    leaving g place = Map.fromAscList (outOf place g.edges)
    uncopiedKeys = Map.mapKeys (renameEvent strip)
    uncopied = renameState strip
    strip text = fromMaybe text (Text.stripPrefix (nameText copy <> "/") text)

{- | The graph with the scope's prefix taken off every name it holds. A name
without the prefix keeps a mark, so it cannot pass for one the scope named.
-}
unscoped :: Name -> OpenGraph -> OpenGraph
unscoped scope g =
    OpenGraph
        { inPort = place g.inPort
        , edges = Map.fromList [((place from, renameEvent bare event), renameEdge edge) | ((from, event), edge) <- Map.toList g.edges]
        , loops = Map.fromList [(renameName bare loop, at {entry = place at.entry, body = Set.map place at.body}) | (loop, at) <- Map.toList g.loops]
        , caps = Map.mapKeys (\metered -> metered {place = place metered.place}) g.caps
        , groupStates = Map.mapKeys place (fmap renameGroup g.groupStates)
        }
  where
    renameGroup = \case
        Graph.Forking group -> Graph.Forking group {Graph.group = renameName bare group.group}
        Graph.Awaiting group -> Graph.Awaiting group {Graph.group = renameName bare group.group}
    bare text = fromMaybe ("unscoped:" <> text) (Text.stripPrefix (nameText scope <> "/") text)
    place at = let (inner, name) = unqualify (bare (stateNameText (placeName at))) in at {scope = inner, name = StateName name}
    renameEdge edge =
        Edge
            { to = case edge.to of
                At at -> At (place at)
                Out -> Out
                Graph.Exit -> Graph.Exit
            , arrow = renameArrow bare edge.arrow
            , back = renameName bare <$> edge.back
            }

renameArrow :: (Text -> Text) -> Arrow -> Arrow
renameArrow f = \case
    Along along -> Along along {event = renameEvent f along.event}
    Stay -> Stay

renameEvent :: (Text -> Text) -> EventName -> EventName
renameEvent f (EventName from outcome) = EventName (renameState f from) outcome

renameState :: (Text -> Text) -> StateName -> StateName
renameState f (StateName text) = StateName (f text)

renameName :: (Text -> Text) -> Name -> Name
renameName f (Name text) = Name (f text)

stateNames :: OpenGraph -> Set.Set StateName
stateNames = Set.map placeName . places

{- | Each meter's and skip's name, and whether its 'PerFuel' is monotone:
more Fuel never allows less, nor skips where less Fuel runs.
-}
budgetsOf :: Flow s i e o -> [(Name, Bool)]
budgetsOf = \case
    Do s -> [(name, skipped skips) | Just (name, skips) <- [skipOf s]]
    Capped limit _ (Step s) -> [(Name (meterName s), capped limit)]
    Capped limit _ (ForkOf _ s) -> [(Name (meterName s), capped limit)]
    Id -> []
    Into -> []
    f :> g -> budgetsOf f <> budgetsOf g
    Loop _ body -> budgetsOf body
    Case branches -> concat (branchesWith budgetsOf branches)
    Flow.Exit -> []
    Each body -> budgetsOf body
    Fork _ body -> budgetsOf body
    Await _ -> []
    Catch body -> budgetsOf body
    Scope _ body -> budgetsOf body
    Handle _ body -> budgetsOf body
  where
    capped :: PerFuel Limit -> Bool
    capped = monotone limitAtMost
    skipped :: PerFuel SkipWhen -> Bool
    skipped = monotone (flip skipsAtMost)

-- | A skip step's name and the levels that skip its block.
skipOf :: forall k (s :: k). (StepSet k) => Sing s -> Maybe (Name, PerFuel SkipWhen)
skipOf s = case eqT @k @FuelStep of
    Just Refl -> case s of
        Skip name skips -> Just (name, skips)
        Fuel -> Nothing
    Nothing -> Nothing

-- | The caps spent at a state, by the step each meters.
capsAt :: Place -> OpenGraph -> [(StateName, Cap)]
capsAt place g = [(metered.step, cap) | (metered, cap) <- Map.toList g.caps, metered.place == place]
