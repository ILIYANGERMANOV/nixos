{- | A worktree as git reports it: its git dir, HEAD, branch, and the
@--numstat@ of HEAD against each base that origin has. Or no git on the
@PATH@ at all. A directory in one of the other worktrees is in that one.
-}
module Doubles.Git (Worktree (..), runGitScripted, runGitMissing) where

import Data.List (isPrefixOf)
import Data.Text (Text)
import Doubles.FileSystem (Disk (..))
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Exception (throwIO)
import Effectful.State.Static.Local (State, gets)
import Effects.Git (Git (..))
import State.Run.Event (Branch (..), Sha)
import System.FilePath (splitDirectories, takeDirectory, (</>))
import System.IO.Error (doesNotExistErrorType, mkIOError)

data Worktree = Worktree
    { gitDir :: Either Text FilePath
    -- ^ Or why git found no work tree.
    , head :: Maybe Sha
    , branch :: Maybe Branch
    , numstats :: [(Branch, Text)]
    -- ^ By base branch; a base origin lacks fails as git does.
    , others :: [FilePath]
    -- ^ The other worktrees' tops, each with its git dir at its top's @.git@.
    , origin :: Maybe Text
    -- ^ The URL of the remote @origin@ every worktree shares, if there is one.
    }

runGitScripted :: (State Disk :> es) => Worktree -> Eff (Git : es) a -> Eff es a
runGitScripted worktree = interpret $ \_ -> \case
    GitDir -> gitDirHere worktree
    -- A main worktree's git dir is its top's @.git@.
    Toplevel -> fmap takeDirectory <$> gitDirHere worktree
    HeadSha -> pure worktree.head
    HeadBranch -> pure worktree.branch
    Numstat base@(Branch name) -> pure $ case lookup base worktree.numstats of
        Just out -> Right out
        Nothing ->
            Left
                ( "git diff --numstat origin/"
                    <> name
                    <> "...HEAD: fatal: ambiguous argument 'origin/"
                    <> name
                    <> "...HEAD': unknown revision or path not in the working tree."
                )
    OriginUrl ->
        pure
            ( maybe
                (Left "git remote get-url origin: error: No such remote 'origin'")
                Right
                worktree.origin
            )

-- | The git dir of the worktree the current directory is in.
gitDirHere :: (State Disk :> es) => Worktree -> Eff es (Either Text FilePath)
gitDirHere worktree = do
    cwd <- gets @Disk (.cwd)
    pure $ case [ top
                | top <- worktree.others
                , splitDirectories top `isPrefixOf` splitDirectories cwd
                ] of
        top : _ -> Right (top </> ".git")
        [] -> worktree.gitDir

-- | No git to start: every call throws as the real spawn does, does-not-exist.
runGitMissing :: Eff (Git : es) a -> Eff es a
runGitMissing = interpret $ \_ _ ->
    throwIO
        ( mkIOError
            doesNotExistErrorType
            "readCreateProcessWithExitCode: posix_spawnp"
            Nothing
            (Just "git")
        )
