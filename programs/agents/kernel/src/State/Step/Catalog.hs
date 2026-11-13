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
    stepNamed,
    nodeStep,
) where

import Data.Aeson (Object)
import Data.Aeson.Types (Parser, Series)
import Data.Type.Equality ((:~:) (..))
import State.Category.Graph (Node (..), Place (..))
import State.Category.Step (Decoder, EventName, SomeOutcome, SomeStep (..), StateName, StepSet (..), decodeWith, decoderEvent, payload)
import State.Category.Step qualified as Step
import State.Step.Build (BuildStep)
import State.Step.Fan (FanStep)
import State.Step.Gather (GatherStep)
import State.Step.Plan (PlanStep)
import State.Step.Review (ReviewStep)
import State.Step.Ship (ShipStep)

-- | A layer of steps, by the kind of its steps.
data Layer k where
    GatherLayer :: Layer GatherStep
    PlanLayer :: Layer PlanStep
    BuildLayer :: Layer BuildStep
    ReviewLayer :: Layer ReviewStep
    ShipLayer :: Layer ShipStep
    FanLayer :: Layer FanStep

deriving stock instance Show (Layer k)

-- | The layer a kind of steps is, so an outcome names its own.
class (StepSet k) => KnownLayer k where
    layer :: Layer k

instance KnownLayer GatherStep where layer = GatherLayer
instance KnownLayer PlanStep where layer = PlanLayer
instance KnownLayer BuildStep where layer = BuildLayer
instance KnownLayer ReviewStep where layer = ReviewLayer
instance KnownLayer ShipStep where layer = ShipLayer
instance KnownLayer FanStep where layer = FanLayer

-- | The layers, in the order the flows run them.
layers :: [SomeLayer]
layers = [SomeLayer GatherLayer, SomeLayer PlanLayer, SomeLayer BuildLayer, SomeLayer ReviewLayer, SomeLayer ShipLayer, SomeLayer FanLayer]
  where
    _listsEvery :: Layer k -> ()
    _listsEvery = \case
        GatherLayer -> ()
        PlanLayer -> ()
        BuildLayer -> ()
        ReviewLayer -> ()
        ShipLayer -> ()
        FanLayer -> ()

data SomeLayer where
    SomeLayer :: (KnownLayer k) => Layer k -> SomeLayer

sameLayer :: Layer a -> Layer b -> Maybe (a :~: b)
sameLayer a b = case (a, b) of
    (GatherLayer, GatherLayer) -> Just Refl
    (PlanLayer, PlanLayer) -> Just Refl
    (BuildLayer, BuildLayer) -> Just Refl
    (ReviewLayer, ReviewLayer) -> Just Refl
    (ShipLayer, ShipLayer) -> Just Refl
    (FanLayer, FanLayer) -> Just Refl
    _ -> Nothing

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

-- | A reader per outcome of every layer, each keyed by the event it reads.
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

-- | The step a state is named after; a fan-out's state names none.
stepNamed :: StateName -> Maybe AnyStep
stepNamed name = lookup name [(nameOf some, some) | some <- allSteps]
  where
    nameOf (AnyStep _ (SomeStep s)) = stepName s

-- | The step the run does at a node: none at a port, nor at a fan-out's state.
nodeStep :: Node -> Maybe AnyStep
nodeStep = \case
    At place -> stepNamed place.name
    Out -> Nothing
    Exit -> Nothing
