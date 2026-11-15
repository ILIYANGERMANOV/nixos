-- | A clock stopped at one instant.
module Doubles.Clock (runClockFixed) where

import Data.Time (UTCTime)
import Effectful (Eff)
import Effectful.Dispatch.Dynamic (interpret)
import Effects.Clock (Clock (..))

runClockFixed :: UTCTime -> Eff (Clock : es) a -> Eff es a
runClockFixed at = interpret $ \_ -> \case
    Now -> pure at
