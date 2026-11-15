-- | The process environment: the variables the installed wrapper and the session set.
module Effects.Environment (
    Environment (..),
    lookupEnv,
    runEnvironmentIO,
) where

import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import System.Environment qualified as Environment

data Environment :: Effect where
    LookupEnv :: String -> Environment m (Maybe String)

type instance DispatchOf Environment = Dynamic

lookupEnv :: (Environment :> es) => String -> Eff es (Maybe String)
lookupEnv = send . LookupEnv

runEnvironmentIO :: (IOE :> es) => Eff (Environment : es) a -> Eff es a
runEnvironmentIO = interpret $ \_ -> \case
    LookupEnv name -> liftIO (Environment.lookupEnv name)
