{- | The run's PR on GitHub, read with the @gh@ on PATH in the current
directory, under a timeout: the branch's, or the one a round names. The
effect hands back what @gh@ did, unread:
'State.Protocol.Advice.pullRequestOf' reads it.
-}
module Effects.Gh (
    Gh (..),
    prView,
    runGhIO,
) where

import Data.Text qualified as Text
import Effectful (
    Dispatch (Dynamic),
    DispatchOf,
    Eff,
    Effect,
    IOE,
    liftIO,
    (:>),
 )
import Effectful.Dispatch.Dynamic (interpret, send)
import State.Protocol.Advice (PrView (..), prViewFields)
import State.Step.Artifact (Shape (..), urlText)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)

data Gh :: Effect where
    PrView :: Shape -> Gh m PrView

type instance DispatchOf Gh = Dynamic

-- | What @gh pr view@ did for the run's PR, by the run's shape.
prView :: (Gh :> es) => Shape -> Eff es PrView
prView = send . PrView

runGhIO :: (IOE :> es) => Eff (Gh : es) a -> Eff es a
runGhIO = interpret $ \_ -> \case
    PrView shape ->
        liftIO
            (timeout (seconds * 1000000) (readProcessWithExitCode "gh" (prViewArgs shape) ""))
            >>= \case
                Nothing -> pure (PrViewTimedOut seconds)
                Just (ExitSuccess, out, _) -> pure (PrViewPrinted (Text.pack out))
                Just (ExitFailure _, _, err) -> pure (PrViewFailed (Text.pack err))

-- | A run's own PR is its branch's; a round's is the one it names, read by URL.
prViewArgs :: Shape -> [String]
prViewArgs shape = ["pr", "view"] <> which <> ["--json", Text.unpack prViewFields]
  where
    which = case shape of
        OwnPr -> []
        RoundOn url -> [Text.unpack (urlText url)]

-- | How long @gh pr view@ may take before the shell goes on without GitHub.
seconds :: Int
seconds = 10
