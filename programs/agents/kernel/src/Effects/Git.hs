{- | What the shell reads of the worktree from git: the git on PATH, run in
the current directory. A failed git command is the first line of why.
-}
module Effects.Git (
    Git (..),
    gitDir,
    toplevel,
    headSha,
    headBranch,
    numstat,
    runGitIO,
) where

import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import State.Event (Branch (..), Sha (..))
import State.Show (firstLine)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data Git :: Effect where
    GitDir :: Git m (Either Text FilePath)
    Toplevel :: Git m (Either Text FilePath)
    HeadSha :: Git m (Maybe Sha)
    HeadBranch :: Git m (Maybe Branch)
    Numstat :: Branch -> Git m (Either Text Text)

type instance DispatchOf Git = Dynamic

-- | The worktree's absolute git dir, or why git found none.
gitDir :: (Git :> es) => Eff es (Either Text FilePath)
gitDir = send GitDir

-- | The worktree's absolute top directory, or why git found none.
toplevel :: (Git :> es) => Eff es (Either Text FilePath)
toplevel = send Toplevel

-- | HEAD, or 'Nothing' before the first commit.
headSha :: (Git :> es) => Eff es (Maybe Sha)
headSha = send HeadSha

-- | The branch HEAD is on, or 'Nothing' when it is detached.
headBranch :: (Git :> es) => Eff es (Maybe Branch)
headBranch = send HeadBranch

-- | @git diff --numstat@ of HEAD against its merge base with the base on origin, or why it failed.
numstat :: (Git :> es) => Branch -> Eff es (Either Text Text)
numstat = send . Numstat

runGitIO :: (IOE :> es) => Eff (Git : es) a -> Eff es a
runGitIO = interpret $ \_ -> \case
    GitDir -> fmap (Text.unpack . Text.strip) <$> git ["rev-parse", "--absolute-git-dir"]
    Toplevel -> fmap (Text.unpack . Text.strip) <$> git ["rev-parse", "--show-toplevel"]
    HeadSha -> either (const Nothing) (Just . Sha . Text.strip) <$> git ["rev-parse", "--verify", "--quiet", "HEAD"]
    HeadBranch -> either (const Nothing) (Just . Branch . Text.strip) <$> git ["symbolic-ref", "--short", "--quiet", "HEAD"]
    Numstat (Branch base) -> git ["diff", "--numstat", "origin/" <> base <> "...HEAD"]

-- | Stdout, or the first line of why git failed.
git :: (IOE :> es) => [Text] -> Eff es (Either Text Text)
git args =
    liftIO (readProcessWithExitCode "git" (map Text.unpack args) "") >>= \case
        (ExitSuccess, out, _) -> pure (Right (Text.pack out))
        (ExitFailure code, _, err) -> pure (Left ("git " <> Text.unwords args <> ": " <> orExit code (firstLine err)))
  where
    orExit code line = if Text.null line then "exit " <> Text.pack (show code) else line
