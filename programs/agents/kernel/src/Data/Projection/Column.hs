{- | Column values more than one projection writes, from domain values: a
run's id and a time. Only the projections' rows functions import it: it
names domain types, which the store must not reach.
-}
module Data.Projection.Column (runIdValue, timeValue) where

import Data.Field qualified as Field
import Data.Projection (Value (..))
import Data.Time (UTCTime)
import State.Run.Event (RunId, runIdText)

runIdValue :: RunId -> Value
runIdValue = SqlText . runIdText

-- | A time as the store spells it ("Data.Field"'s @time@ column).
timeValue :: UTCTime -> Value
timeValue = SqlText . Field.encode Field.time
