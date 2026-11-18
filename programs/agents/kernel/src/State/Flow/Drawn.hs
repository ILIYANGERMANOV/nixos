{- | The steps the roles' flows draw that no layer lists: each pick, with
its labels, and each skip. Their events carry no data, so each outcome is
its own reader.
-}
module State.Flow.Drawn (
    drawnSteps,
    drawnOutcomes,
    drawnDecoders,
    SkipHere (..),
    skipHere,
    fuelTakes,
    isPick,
) where

import Data.Aeson (Object)
import Data.Aeson.Types (Parser)
import Data.Function (on)
import Data.List (nubBy)
import Data.Maybe (listToMaybe)
import State.Category.Flow (Name)
import State.Category.Fuel (Fuel, PerFuel, SkipWhen (Never), atFuel)
import State.Category.Step (EventName (..), SomeStep (..), StateName, StepSet (stepName))
import State.Role (RoleDef (..), SomeFlow (..), roles)
import State.Step.Catalog (AnyOutcome, AnyStep (..), Layer (FuelLayer, PickLayer), flowOutcomes, outcome, outcomeEvent, termSteps)
import State.Step.Fuel (Outcome (Running, Skipping), Sing (Skip))

{- | Once per name: two flows drawing one name draw one step, or the step
table's check finds two readers of one event.
-}
drawnSteps :: [AnyStep]
drawnSteps = nubBy ((==) `on` nameOf) [step | RoleDef {flow = SomeFlow flow} <- roles, step <- termSteps flow]
  where
    nameOf (AnyStep _ (SomeStep s)) = stepName s

-- | Each drawn step's outcomes, in the flows' order.
drawnOutcomes :: [AnyOutcome]
drawnOutcomes = concatMap flowOutcomes drawnSteps

-- | A reader per drawn outcome, keyed by its event as 'State.Step.Catalog.outcomeDecoders' are.
drawnDecoders :: [(EventName, Object -> Parser AnyOutcome)]
drawnDecoders = [(outcomeEvent o, const (pure o)) | o <- drawnOutcomes]

-- | A skip step: its block, the levels that skip it, and its two outcomes.
data SkipHere = SkipHere {block :: Name, when :: PerFuel SkipWhen, skips :: AnyOutcome, runs :: AnyOutcome}

-- | The skip step of this name, when the flows draw one.
skipHere :: StateName -> Maybe SkipHere
skipHere name =
    listToMaybe
        [ SkipHere block when (outcome (Skipping s)) (outcome (Running s))
        | AnyStep FuelLayer (SomeStep s@(Skip block when)) <- drawnSteps
        , stepName s == name
        ]

-- | Whether a run at this Fuel takes the event out of the state: a skip its level never makes is no way on.
fuelTakes :: Fuel -> StateName -> EventName -> Bool
fuelTakes fuel name event = case skipHere name of
    Just skip | atFuel fuel skip.when == Never -> event.outcome /= (outcomeEvent skip.skips).outcome
    _ -> True

-- | Whether the flows draw a pick of this name: the agent picks its branch by label.
isPick :: StateName -> Bool
isPick name = or [stepName s == name | AnyStep PickLayer (SomeStep s) <- drawnSteps]
