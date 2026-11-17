{- | The steps the roles' flows draw that no layer lists: each pick, with
its labels, and each skip. Their events carry no data, so each outcome is
its own reader.
-}
module State.Flow.Drawn (
    drawnSteps,
    drawnOutcomes,
    drawnDecoders,
) where

import Data.Aeson (Object)
import Data.Aeson.Types (Parser)
import Data.Function (on)
import Data.List (nubBy)
import State.Category.Step (EventName, SomeStep (..), StepSet (stepName))
import State.Role (RoleDef (..), SomeFlow (..), roles)
import State.Step.Catalog (AnyOutcome, AnyStep (..), flowOutcomes, outcomeEvent, termSteps)

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
