{- | What the shell reads of the worktree and its PR: git and @gh@ from PATH,
run in the current directory. GitHub is read under a timeout, and when it
cannot be read the advice goes on without it, saying why.
-}
module State.Shell.Repo (
    gitDir,
    headSha,
    readFacts,
    changedLines,
    parsePr,
) where

import Data.Aeson (eitherDecodeStrictText, withObject, (.:))
import Data.Aeson.Types (parseEither)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Read (decimal)
import Numeric.Natural (Natural)
import State.Advice (Facts (..), PullRequest (..), Readiness (..))
import State.Cli (Exit (..), Failure (..))
import State.Event (Branch (..), DraftPr (..), Sha (..), Url (..))
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)

-- | The worktree's git dir, where the pointer to its run lives.
gitDir :: IO (Either Failure FilePath)
gitDir =
    git ["rev-parse", "--absolute-git-dir"] >>= \case
        Right out -> pure (Right (Text.unpack (Text.strip out)))
        Left why -> pure (Left (Failure BadInput "not inside a git work tree" why "cd <worktree>; state keeps one run per worktree"))

-- | HEAD, or 'Nothing' before the first commit.
headSha :: IO (Maybe Sha)
headSha = either (const Nothing) (Just . Sha . Text.strip) <$> git ["rev-parse", "--verify", "--quiet", "HEAD"]

{- | The branch's PR on GitHub and the lines it changes, each 'Nothing' when
it cannot be read, with a line saying why.
-}
readFacts :: IO (Facts, [Text])
readFacts =
    prView >>= \case
        Left why -> pure (Facts Nothing Nothing, ["PR sync skipped - " <> why])
        Right Nothing -> pure (Facts Nothing Nothing, [])
        Right (Just pr) -> do
            let Branch base = pr.draft.base
            git ["diff", "--numstat", "origin/" <> base <> "...HEAD"] >>= \case
                Right out -> pure (Facts (Just (changedLines out)) (Just pr), [])
                Left why -> pure (Facts Nothing (Just pr), ["changed lines unknown - " <> why])

{- | @git diff --numstat@'s added plus deleted lines, as the Quality table
counts them: generated lockfiles and binary files add none.
-}
changedLines :: Text -> Natural
changedLines = sum . map counted . Text.lines
  where
    counted row = case Text.splitOn "\t" row of
        [added, deleted, path] | not (lockfile path) -> number added + number deleted
        _ -> 0
    number raw = case decimal raw of
        Right (n, "") -> n
        -- A binary file's row reads @-@.
        _ -> 0
    lockfile path = case reverse (Text.splitOn "/" path) of
        name : _ -> name `elem` ["flake.lock", "package-lock.json", "pnpm-lock.yaml"] || ".lock" `Text.isSuffixOf` name
        [] -> False

-- | The branch's PR, 'Nothing' when it has none, or why GitHub was not read.
prView :: IO (Either Text (Maybe PullRequest))
prView =
    timeout (10 * 1000000) (readProcessWithExitCode "gh" ["pr", "view", "--json", "url,baseRefName,headRefName,isDraft"] "") >>= \case
        Nothing -> pure (Left "gh pr view timed out after 10s")
        Just (ExitSuccess, out, _) -> pure (Just <$> parsePr (Text.pack out))
        Just (ExitFailure _, _, err)
            | "no pull requests found" `Text.isInfixOf` Text.pack err -> pure (Right Nothing)
            | otherwise -> pure (Left ("gh pr view: " <> firstLine err))

-- | @gh pr view --json url,baseRefName,headRefName,isDraft@'s object.
parsePr :: Text -> Either Text PullRequest
parsePr out = either (Left . ("gh pr view printed no PR: " <>) . Text.pack) Right $ do
    value <- eitherDecodeStrictText out
    flip parseEither value $ withObject "PR" $ \o -> do
        draft <- DraftPr . Url <$> o .: "url" <*> (Branch <$> o .: "baseRefName") <*> (Branch <$> o .: "headRefName")
        isDraft <- o .: "isDraft"
        pure (PullRequest draft (if isDraft then IsDraft else IsReady))

-- | Stdout, or the first line of why git failed.
git :: [Text] -> IO (Either Text Text)
git args =
    readProcessWithExitCode "git" (map Text.unpack args) "" >>= \case
        (ExitSuccess, out, _) -> pure (Right (Text.pack out))
        (ExitFailure code, _, err) -> pure (Left ("git " <> Text.unwords args <> ": " <> orExit code (firstLine err)))
  where
    orExit code line = if Text.null line then "exit " <> Text.pack (show code) else line

firstLine :: String -> Text
firstLine = Text.strip . Text.takeWhile (/= '\n') . Text.pack
