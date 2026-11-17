{- | Every layer of steps, closed: a run's outcome is one of some layer's,
so a match over 'Layer' is a match over every step there is. A new layer is
its module, its 'Layer' constructor here, and the arm each match on 'Layer'
then asks for.
-}
module State.Step.Catalog (
    Layer (..),
    KnownLayer (..),
    AnyOutcome (..),
    outcome,
    outcomeEvent,
    outcomeData,
    outcomeDecoders,
    AnyStep (..),
    allSteps,
    termSteps,
    termSkips,
    flowOutcomes,
    stepNamed,
    shownEdges,
) where

import Data.Aeson (Object)
import Data.Aeson.Types (Parser, Series)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Type.Equality ((:~:) (..))
import Data.Typeable (eqT)
import State.Category.Flow (Cappable (..), Flow (Await, Capped, Case, Catch, Choice, Do, Each, Fork, Id, Into, Loop, Par, Route, Scope, (:>)), Name, branchesWith)
import State.Category.Flow qualified as Flow
import State.Category.Fuel (PerFuel, SkipWhen)
import State.Category.Graph (Cap (..), Edge, Metered (..), Node (..), OpenGraph (..), Place (..))
import State.Category.Step (CodOf, Decoder, DomOf, EventName (..), Sig, SomeOutcome, SomeStep (..), StateName, StepSet (..), decodeWith, decoderEvent, payload)
import State.Category.Step qualified as Step
import State.Category.Ty (KnownTy)
import State.Step.Build (BuildStep)
import State.Step.Choice (ChoiceStep)
import State.Step.Fan (FanStep)
import State.Step.Fuel (FuelStep, Sing (Skip), skipOutcomes)
import State.Step.Gather (GatherStep)
import State.Step.Pick (PickStep, pickOutcomes)
import State.Step.Plan (PlanStep)
import State.Step.Request (RequestStep)
import State.Step.Review (ReviewStep)
import State.Step.Ship (ShipStep)
import State.Step.Ticket (TicketStep)

-- | A layer of steps, by the kind of its steps.
data Layer k where
    GatherLayer :: Layer GatherStep
    PlanLayer :: Layer PlanStep
    BuildLayer :: Layer BuildStep
    ReviewLayer :: Layer ReviewStep
    ShipLayer :: Layer ShipStep
    TicketLayer :: Layer TicketStep
    RequestLayer :: Layer RequestStep
    FanLayer :: Layer FanStep
    ChoiceLayer :: Layer ChoiceStep
    PickLayer :: Layer PickStep
    FuelLayer :: Layer FuelStep

deriving stock instance Show (Layer k)

-- | The layer a kind of steps is, so an outcome names its own.
class (StepSet k) => KnownLayer k where
    layer :: Layer k

instance KnownLayer GatherStep where layer = GatherLayer
instance KnownLayer PlanStep where layer = PlanLayer
instance KnownLayer BuildStep where layer = BuildLayer
instance KnownLayer ReviewStep where layer = ReviewLayer
instance KnownLayer ShipStep where layer = ShipLayer
instance KnownLayer TicketStep where layer = TicketLayer
instance KnownLayer RequestStep where layer = RequestLayer
instance KnownLayer FanStep where layer = FanLayer
instance KnownLayer ChoiceStep where layer = ChoiceLayer
instance KnownLayer PickStep where layer = PickLayer
instance KnownLayer FuelStep where layer = FuelLayer

-- | The layers, in the order the flows run them.
layers :: [SomeLayer]
layers = [SomeLayer GatherLayer, SomeLayer PlanLayer, SomeLayer BuildLayer, SomeLayer ReviewLayer, SomeLayer ShipLayer, SomeLayer TicketLayer, SomeLayer RequestLayer, SomeLayer FanLayer, SomeLayer ChoiceLayer, SomeLayer PickLayer, SomeLayer FuelLayer]
  where
    _listsEvery :: Layer k -> ()
    _listsEvery = \case
        GatherLayer -> ()
        PlanLayer -> ()
        BuildLayer -> ()
        ReviewLayer -> ()
        ShipLayer -> ()
        TicketLayer -> ()
        RequestLayer -> ()
        FanLayer -> ()
        ChoiceLayer -> ()
        PickLayer -> ()
        FuelLayer -> ()

data SomeLayer where
    SomeLayer :: (KnownLayer k) => Layer k -> SomeLayer

sameLayer :: Layer a -> Layer b -> Maybe (a :~: b)
sameLayer a b = case (a, b) of
    (GatherLayer, GatherLayer) -> Just Refl
    (GatherLayer, _) -> Nothing
    (PlanLayer, PlanLayer) -> Just Refl
    (PlanLayer, _) -> Nothing
    (BuildLayer, BuildLayer) -> Just Refl
    (BuildLayer, _) -> Nothing
    (ReviewLayer, ReviewLayer) -> Just Refl
    (ReviewLayer, _) -> Nothing
    (ShipLayer, ShipLayer) -> Just Refl
    (ShipLayer, _) -> Nothing
    (TicketLayer, TicketLayer) -> Just Refl
    (TicketLayer, _) -> Nothing
    (RequestLayer, RequestLayer) -> Just Refl
    (RequestLayer, _) -> Nothing
    (FanLayer, FanLayer) -> Just Refl
    (FanLayer, _) -> Nothing
    (ChoiceLayer, ChoiceLayer) -> Just Refl
    (ChoiceLayer, _) -> Nothing
    (PickLayer, PickLayer) -> Just Refl
    (PickLayer, _) -> Nothing
    (FuelLayer, FuelLayer) -> Just Refl
    (FuelLayer, _) -> Nothing

-- | A step's outcome, or a mode's skip, with the layer it is of.
data AnyOutcome where
    AnyOutcome :: (KnownLayer k) => Layer k -> SomeOutcome k -> AnyOutcome

instance Show AnyOutcome where
    showsPrec d (AnyOutcome _ o) = showsPrec d o

instance Eq AnyOutcome where
    AnyOutcome a o == AnyOutcome b o' = case sameLayer a b of
        Just Refl -> o == o'
        Nothing -> False

-- | An outcome of its layer, packed by the layer's total 'pack'.
outcome :: (KnownLayer k) => Step.Outcome (s :: k) l -> AnyOutcome
outcome o = AnyOutcome layer (pack o)

-- | The graph's name for the edge an outcome takes: its step's, then its leg's.
outcomeEvent :: AnyOutcome -> EventName
outcomeEvent (AnyOutcome _ o) = Step.outcomeEvent o

-- | The outcome's @data@ on the wire.
outcomeData :: AnyOutcome -> Series
outcomeData (AnyOutcome _ o) = payload o

{- | A reader per outcome of every layer, each keyed by the event it reads:
a flow's picks and skips are read where the flows are known ("State.Flow.Drawn").
-}
outcomeDecoders :: [(EventName, Object -> Parser AnyOutcome)]
outcomeDecoders = concatMap readers layers
  where
    readers (SomeLayer l) = map (reader l) decoders
    reader :: (KnownLayer k) => Layer k -> Decoder k -> (EventName, Object -> Parser AnyOutcome)
    reader l d = (decoderEvent d, fmap (AnyOutcome l) . decodeWith d)

-- | A step of some layer, with its types known.
data AnyStep where
    AnyStep :: (KnownLayer k) => Layer k -> SomeStep k -> AnyStep

-- | Every step 'State.Category.Flow.Do' draws, layer by layer, in the order the flows run them.
allSteps :: [AnyStep]
allSteps = concatMap stepsOf layers
  where
    stepsOf (SomeLayer l) = map (AnyStep l) layerSteps

{- | The pick and skip steps of a term: a flow names its own, with its
labels, so no layer lists them. In the term's order; a fork's child is
its own run, of its own flow.
-}
termSteps :: Flow i e o -> [AnyStep]
termSteps = \case
    Do s -> drawnStep s
    Capped _ _ (Step s) -> drawnStep s
    -- The forked step is the child's: no pick or skip of this flow.
    Capped _ _ (ForkOf _ _) -> []
    Id -> []
    Into -> []
    f :> g -> termSteps f <> termSteps g
    Loop _ body -> termSteps body
    Par _ _ -> []
    Case branches -> concat (branchesWith termSteps branches)
    Flow.Exit -> []
    Each body -> termSteps body
    Fork _ _ -> []
    Await _ -> []
    Catch body -> termSteps body
    Scope _ body -> termSteps body
    Choice _ actions -> concatMap termSteps actions
    Route _ branches -> concatMap (termSteps . snd) branches

-- | Each optional block of a term, by its name, with the levels that skip it: in the term's order.
termSkips :: Flow i e o -> [(Name, PerFuel SkipWhen)]
termSkips flow = [(name, when) | AnyStep FuelLayer (SomeStep (Skip name when)) <- termSteps flow]

-- | The step, when it is a pick or a skip: a layer that lists its steps has it in 'allSteps'.
drawnStep :: forall k (s :: k). (StepSet k, KnownTy (DomOf (Sig s)), KnownTy (CodOf (Sig s))) => Sing s -> [AnyStep]
drawnStep s = case (eqT @k @PickStep, eqT @k @FuelStep) of
    (Just Refl, _) -> [AnyStep PickLayer (SomeStep s)]
    (_, Just Refl) -> [AnyStep FuelLayer (SomeStep s) | not (null (skipOutcomes s))]
    (Nothing, Nothing) -> []

-- | The outcomes of a flow's pick or skip, which carry no data.
flowOutcomes :: AnyStep -> [AnyOutcome]
flowOutcomes (AnyStep l (SomeStep s)) = case l of
    PickLayer -> map (AnyOutcome PickLayer) (pickOutcomes s)
    FuelLayer -> map (AnyOutcome FuelLayer) (skipOutcomes s)
    GatherLayer -> []
    PlanLayer -> []
    BuildLayer -> []
    ReviewLayer -> []
    ShipLayer -> []
    TicketLayer -> []
    RequestLayer -> []
    FanLayer -> []
    ChoiceLayer -> []

-- | The step a state is named after; a fan-out's state names none.
stepNamed :: StateName -> Maybe AnyStep
stepNamed name = lookup name [(nameOf some, some) | some <- allSteps]
  where
    nameOf (AnyStep _ (SomeStep s)) = stepName s

{- | The edges out of a state in the order they are shown: a choice's
actions' first, in the order the term declares them, each one's outcomes as
its step declares them; then the state's own, by name.
-}
shownEdges :: OpenGraph -> Place -> [(EventName, Edge Node)]
shownEdges g place = sortOn (shown . fst) [(event, edge) | ((from, event), edge) <- Map.toList g.edges, from == place]
  where
    ranks = Map.fromList [(metered.step, cap.rank) | (metered, cap) <- Map.toList g.caps, metered.place == place, metered.step /= place.name]
    shown event = case Map.lookup event.step ranks of
        Just rank -> (0 :: Int, rank, declared event)
        Nothing -> (1, 0, 0)
    declared event = case stepNamed event.step of
        Just (AnyStep _ (SomeStep s)) -> length (takeWhile (/= event.outcome) (Step.outcomeNames (outcomes s)))
        Nothing -> 0
