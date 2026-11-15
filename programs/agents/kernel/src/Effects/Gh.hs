{- | The branch's PR on GitHub, read with the @gh@ on PATH in the current
directory, under a timeout. The effect hands back what @gh@ did, unread:
'State.Protocol.Advice.pullRequestOf' reads it.
-}
module Effects.Gh (
    Gh (..),
    prView,
    runGhIO,
) where

import Data.Text qualified as Text
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import State.Protocol.Advice (PrView (..), prViewFields)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)

data Gh :: Effect where
    PrView :: Gh m PrView

type instance DispatchOf Gh = Dynamic

-- | What @gh pr view@ did for the branch.
prView :: (Gh :> es) => Eff es PrView
prView = send PrView

runGhIO :: (IOE :> es) => Eff (Gh : es) a -> Eff es a
runGhIO = interpret $ \_ -> \case
    PrView ->
        liftIO (timeout (seconds * 1000000) (readProcessWithExitCode "gh" ["pr", "view", "--json", Text.unpack prViewFields] "")) >>= \case
            Nothing -> pure (PrViewTimedOut seconds)
            Just (ExitSuccess, out, _) -> pure (PrViewPrinted (Text.pack out))
            Just (ExitFailure _, _, err) -> pure (PrViewFailed (Text.pack err))

-- | How long @gh pr view@ may take before the shell goes on without GitHub.
seconds :: Int
seconds = 10
