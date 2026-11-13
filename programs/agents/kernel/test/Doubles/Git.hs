{- | A worktree as git reports it: its git dir, HEAD, branch, and the
@--numstat@ of HEAD against each base that origin has.
-}
module Doubles.Git (Worktree (..), runGitScripted) where

import Data.Text (Text)
import Effectful (Eff)
import Effectful.Dispatch.Dynamic (interpret)
import Effects.Git (Git (..))
import State.Event (Branch (..), Sha)
import System.FilePath (takeDirectory)

data Worktree = Worktree
    { gitDir :: Either Text FilePath
    -- ^ Or why git found no work tree.
    , head :: Maybe Sha
    , branch :: Maybe Branch
    , numstats :: [(Branch, Text)]
    -- ^ By base branch; a base origin lacks fails as git does.
    }

runGitScripted :: Worktree -> Eff (Git : es) a -> Eff es a
runGitScripted worktree = interpret $ \_ -> \case
    GitDir -> pure worktree.gitDir
    -- A main worktree's git dir is its top's @.git@.
    Toplevel -> pure (takeDirectory <$> worktree.gitDir)
    HeadSha -> pure worktree.head
    HeadBranch -> pure worktree.branch
    Numstat base@(Branch name) -> pure $ case lookup base worktree.numstats of
        Just out -> Right out
        Nothing -> Left ("git diff --numstat origin/" <> name <> "...HEAD: fatal: ambiguous argument 'origin/" <> name <> "...HEAD': unknown revision or path not in the working tree.")
