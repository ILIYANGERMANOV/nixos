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
import Hedgehog (Gen, forAll, (===))
import Hedgehog.Gen qualified as Gen
import State.Category.Flow (Flow (..), Name (..), inl, inr, nameText, scoped, (|||))
import State.Category.FlowGen (Kit (..), diffKit, genBranching, genEndo, genExiting, genFlow, redrawn)
import State.Category.Fuel (PerFuel, SkipWhen, monotone, skipsAtMost)
import State.Category.Meter (Limit, limitAtMost, meterName)
import State.Category.Graph (Arrow (..), Clash, Edge (..), LoopAt (..), Node (..), OpenGraph (..), Place (..), graph, places)
import State.Category.Step (EventName (..), OutcomeEdge (..), StateName (..))
import State.Category.Ty (NotSum, Ty (..))
import State.Flow.Engineer (engineer)
import State.Flow.TenX (tenX)
import State.Flow.Triage (Sing (..))
import State.Step.Build (Sing (..))
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "laws" $ do
    describe "category" $ do
        it "identity_is_a_unit_of_series" . hedgehog $ do
            f <- forAll (Gen.filter (isRight . graph) genFlow)
            (drawn (Id :> f), drawn (f :> Id)) === (drawn f, drawn f)

        it "series_is_associative" . hedgehog $ do
            (f, g, h) <- forAll (Gen.filter (\(f, g, h) -> isRight (graph ((f :> g) :> h))) ((,,) <$> genExiting diffKit <*> genEndo diffKit <*> genBranching))
            drawn ((f :> g) :> h) === drawn (f :> (g :> h))

    {- The sum in #351: a case after an injection is the branch it injects
    into, a case of the two injections each followed by @h@ is @h@, and the
    case is associative.
    -}
    describe "sums" $ do
        it "inl_then_case_draws_as_the_left_branch" . hedgehog $ do
            (f, g) <- forAll genCase
            drawn (inl :> (f ||| g)) === drawn f

        it "inr_then_case_draws_as_the_right_branch" . hedgehog $ do
            (f, g) <- forAll genCase
            drawn (inr :> (f ||| g)) === drawn g

        -- @Do Triage@ feeds both summands, so both sides draw each branch.
        it "a_case_of_injections_then_h_walks_as_h" . hedgehog $ do
            h <- forAll (Gen.filter (isRight . graph . (Do Triage :>)) genOnSum)
            (bisimilar <$> graph (Do Triage :> ((inl :> h) ||| (inr :> Scope copy h))) <*> graph (Do Triage :> h)) === Right []

        {- @x@ ends in @(Diff + Plan) + Plan@; the associator moves it to
        @Diff + (Plan + Plan)@, so both cases see the same three branches.
        -}
        it "case_is_associative" . hedgehog $ do
            (f, g, h) <- forAll ((,,) <$> genBranching <*> genPlanned <*> genPlanned)
            let x = Do Triage :> (Do Triage :> inl ||| inr)
                associator = (inl ||| inl :> inr) ||| inr :> inr
            drawn (x :> ((f ||| g) ||| h)) === drawn (x :> associator :> (f ||| (g ||| h)))

    describe "Catch, the codiagonal" $ do
        it "catch_moves_past_a_side_with_no_exit" . hedgehog $ do
            (f, g) <- forAll ((,) <$> genEndo diffKit <*> genExiting diffKit)
            drawn (Catch (f :> g)) === drawn (f :> Catch g)

        it "catch_distributes_over_a_case" . hedgehog $ do
            (f, g) <- forAll ((,) <$> genExiting diffKit <*> ((Do Implement :>) <$> genExiting diffKit))
            drawn (Do Triage :> Catch (f ||| g)) === drawn (Do Triage :> (Catch f ||| Catch g))

    describe "Loop, Elgot's fixpoint" $ do
        {- The unrolled round is a second copy of the body's states, whose
        edges start no round: bisimilar, caps and all, not isomorphic.
        -}
        it "a_loop_walks_as_its_body_unrolled_once" . hedgehog $ do
            body <- forAll (Gen.filter (isRight . graph . Loop "review") genBody)
            let loop = Loop "review" body
            (bisimilar <$> graph loop <*> graph (Catch (Scope copy body :> loop))) === Right []

    describe "Scope" $ do
        it "scope_preserves_the_graph_but_its_names" . hedgehog $ do
            f <- forAll (Gen.filter (isRight . graph) genFlow)
            (unscoped "inner" <$> graph (Scope "inner" f)) === graph f

        -- Of a series that builds: a clash inside the scope is named bare on one side, scoped on the other.
        it "scope_distributes_over_series" . hedgehog $ do
            (f, g) <- forAll (Gen.filter (\(f, g) -> isRight (graph (f :> g))) ((,) <$> genExiting diffKit <*> genBranching))
            drawn (Scope "inner" (f :> g)) === drawn (Scope "inner" f :> Scope "inner" g)

        it "nested_scopes_are_one_scope_of_both_names" . hedgehog $ do
            f <- forAll genFlow
            graph (Scope "outer" (Scope "inner" f)) === graph (Scope (scoped "outer" "inner") f)

        it "names_the_states_around_a_scope_as_bare" . hedgehog $ do
            (f, g) <- forAll (Gen.filter (\(f, g) -> isRight (graph (f :> Scope "inner" g))) ((,) <$> genExiting diffKit <*> genBranching))
            (stateNames <$> graph (f :> Scope "inner" g)) === liftA2 (<>) (stateNames <$> graph f) (stateNames <$> graph (Scope "inner" g))

    describe "PerFuel" $
        it "allows each level at least the spends and runs of the level below, in every named flow" $
            [(flow, name) | (flow, budgets) <- [("engineer" :: String, budgetsOf engineer), ("tenX", budgetsOf tenX)], (name, False) <- budgets]
                `shouldBe` []

-- | The graph with each state's path its rank, or the clash that refuses the term.
drawn :: (NotSum i, NotSum o) => Flow i e o -> Either Clash OpenGraph
drawn = fmap redrawn . graph

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

{- | The scope a law's copied subterm sits under: one loop name drawn twice
would mix its rounds ('SameLoop'), so the copy is renamed.
-}
copy :: Name
copy = "u"

-- | A case over a triaged diff, then more steps.
genOnSum :: Gen (Flow ('Diff ':+ 'Plan) 'Nothing 'Diff)
genOnSum =
    Gen.recursive
        Gen.choice
        [(\f g -> f ||| Do Implement :> g) <$> genDiff <*> genDiff]
        [ (:>) <$> genOnSum <*> genDiff
        , Scope "inner" <$> genOnSum
        ]
  where
    genDiff =
        Gen.recursive
            Gen.choice
            [genEndo diffKit]
            [(Do Triage :>) <$> genOnSum]

-- | A loop body with an exit.
genBody :: Gen (Flow 'Diff ('Just 'Diff) 'Diff)
genBody =
    Gen.choice
        [ genExiting diffKit
        , (\f exit g -> f :> exit :> g) <$> genEndo diffKit <*> Gen.element diffKit.exiting <*> genEndo diffKit
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
        | uncopied p.name /= uncopied q.name || Map.keys (uncopiedKeys outP) /= Map.keys (uncopiedKeys outQ) || Map.lookup p left.caps /= Map.lookup q right.caps = Nothing
        | otherwise = concat <$> sequence (Map.elems (Map.intersectionWith step (uncopiedKeys outP) (uncopiedKeys outQ)))
      where
        outP = leaving left p
        outQ = leaving right q
    step a b
        | renameArrow strip a.arrow /= renameArrow strip b.arrow = Nothing
        | otherwise = case (a.to, b.to) of
            (At x, At y) -> Just [(x, y)]
            (Out, Out) -> Just []
            (Exit, Exit) -> Just []
            _ -> Nothing
    leaving g place = Map.fromList [(event, edge) | ((from, event), edge) <- Map.toList g.edges, from == place]
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
        , caps = Map.mapKeys place g.caps
        }
  where
    bare text = fromMaybe ("unscoped:" <> text) (Text.stripPrefix (nameText scope <> "/") text)
    place at = at {name = renameState bare at.name}
    renameEdge edge =
        Edge
            { to = case edge.to of
                At at -> At (place at)
                Out -> Out
                Exit -> Exit
            , arrow = renameArrow bare edge.arrow
            , back = renameName bare <$> edge.back
            }

renameArrow :: (Text -> Text) -> Arrow -> Arrow
renameArrow f = \case
    Along along -> Along along {event = renameEvent f along.event}
    Skip name skips -> Skip (renameName f name) skips
    Stay -> Stay

renameEvent :: (Text -> Text) -> EventName -> EventName
renameEvent f (EventName from outcome) = EventName (renameState f from) outcome

renameState :: (Text -> Text) -> StateName -> StateName
renameState f (StateName text) = StateName (f text)

renameName :: (Text -> Text) -> Name -> Name
renameName f (Name text) = Name (f text)

stateNames :: OpenGraph -> Set.Set StateName
stateNames = Set.map (.name) . places

{- | Each meter's and skip's name, and whether its 'PerFuel' is monotone:
more Fuel never allows less, nor skips where less Fuel runs.
-}
budgetsOf :: Flow i e o -> [(Name, Bool)]
budgetsOf = \case
    Do _ -> []
    Capped limit _ s -> [(Name (meterName s), capped limit)]
    Id -> []
    f :> g -> budgetsOf f <> budgetsOf g
    Loop _ body -> budgetsOf body
    Opt name skips body -> (name, skipped skips) : budgetsOf body
    Par _ body -> budgetsOf body
    InL -> []
    InR -> []
    f :||| g -> budgetsOf f <> budgetsOf g
    Catch body -> budgetsOf body
    Scope _ body -> budgetsOf body
  where
    capped :: PerFuel Limit -> Bool
    capped = monotone limitAtMost
    skipped :: PerFuel SkipWhen -> Bool
    skipped = monotone (flip skipsAtMost)
