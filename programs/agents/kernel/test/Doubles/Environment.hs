-- | A process environment of the given variables only.
module Doubles.Environment (runEnvironmentGiven) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Effectful (Eff)
import Effectful.Dispatch.Dynamic (interpret)
import Effects.Environment (Environment (..))

runEnvironmentGiven :: Map String String -> Eff (Environment : es) a -> Eff es a
runEnvironmentGiven vars = interpret $ \_ -> \case
    LookupEnv name -> pure (Map.lookup name vars)
