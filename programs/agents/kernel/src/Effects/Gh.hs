{- | The branch's PR on GitHub, read with the @gh@ on PATH in the current
directory, under a timeout: when GitHub cannot be read the shell goes on
without it, saying why.
-}
module Effects.Gh (
    Gh (..),
    prView,
    runGhIO,
) where

import Data.Aeson (eitherDecodeStrictText, withObject, (.:))
import Data.Aeson.Types (parseEither)
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import State.Advice (PullRequest (..), Readiness (..))
import State.Event (Branch (..), DraftPr (..), Url (..))
import State.Show (firstLine)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)

data Gh :: Effect where
    PrView :: Gh m (Either Text (Maybe PullRequest))

type instance DispatchOf Gh = Dynamic

-- | The branch's PR, 'Nothing' when it has none, or why GitHub was not read.
prView :: (Gh :> es) => Eff es (Either Text (Maybe PullRequest))
prView = send PrView

runGhIO :: (IOE :> es) => Eff (Gh : es) a -> Eff es a
runGhIO = interpret $ \_ -> \case
    PrView ->
        liftIO (timeout (10 * 1000000) (readProcessWithExitCode "gh" ["pr", "view", "--json", "url,baseRefName,headRefName,isDraft,state"] "")) >>= \case
            Nothing -> pure (Left "gh pr view timed out after 10s")
            Just (ExitSuccess, out, _) -> pure (Just <$> parsePr (Text.pack out))
            Just (ExitFailure _, _, err)
                | "no pull requests found" `Text.isInfixOf` Text.pack err -> pure (Right Nothing)
                | otherwise -> pure (Left ("gh pr view: " <> firstLine err))

-- | @gh pr view --json url,baseRefName,headRefName,isDraft,state@'s object.
parsePr :: Text -> Either Text PullRequest
parsePr out = either (Left . ("gh pr view printed no PR: " <>) . Text.pack) Right $ do
    value <- eitherDecodeStrictText out
    flip parseEither value $ withObject "PR" $ \o -> do
        draft <- DraftPr . Url <$> o .: "url" <*> (Branch <$> o .: "baseRefName") <*> (Branch <$> o .: "headRefName")
        isDraft <- o .: "isDraft"
        prState <- o .: "state"
        PullRequest draft <$> case (prState :: Text, isDraft) of
            ("OPEN", True) -> pure IsDraft
            ("OPEN", False) -> pure IsReady
            ("MERGED", _) -> pure IsMerged
            ("CLOSED", _) -> pure IsClosed
            _ -> fail ("unknown PR state " <> Text.unpack prState)
