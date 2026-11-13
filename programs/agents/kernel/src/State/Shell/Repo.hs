{- | What the shell reads of the worktree and its PR, and where the worktree's
run lives: a pointer file in the git dir names the notes dir, which holds
@events.jsonl@. GitHub that cannot be read leaves the advice to go on without
it, saying why.
-}
module State.Shell.Repo (
    gitDir,
    readPointer,
    writePointer,
    readFacts,
) where

import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, (:>))
import Effects.FileSystem (FileSystem)
import Effects.FileSystem qualified as FileSystem
import Effects.Gh (Gh)
import Effects.Gh qualified as Gh
import Effects.Git (Git)
import Effects.Git qualified as Git
import State.Advice (Facts (..), PullRequest (..), changedLinesOf)
import State.Cli (Exit (..), Failure (..))
import State.Event (DraftPr (..))
import System.FilePath ((</>))

-- | The worktree's git dir, where the pointer to its run lives.
gitDir :: (Git :> es) => Eff es (Either Failure FilePath)
gitDir = first (\why -> Failure BadInput "not inside a git work tree" why "cd <worktree>; state keeps one run per worktree") <$> Git.gitDir

-- | The notes dir the worktree's run keeps, if a run was started here.
readPointer :: (FileSystem :> es) => FilePath -> Eff es (Maybe FilePath)
readPointer dir = fmap (Text.unpack . Text.strip) <$> FileSystem.readText (pointerOf dir)

writePointer :: (FileSystem :> es) => FilePath -> FilePath -> Eff es ()
writePointer dir notes = FileSystem.writeText (pointerOf dir) (Text.pack notes <> "\n")

pointerOf :: FilePath -> FilePath
pointerOf dir = dir </> "state-notes"

{- | The branch's PR on GitHub and the lines it changes, each 'Nothing' when
it cannot be read, with a line saying why.
-}
readFacts :: (Gh :> es, Git :> es) => Eff es (Facts, [Text])
readFacts =
    Gh.prView >>= \case
        Left why -> pure (Facts Nothing Nothing, ["PR sync skipped - " <> why])
        Right Nothing -> pure (Facts Nothing Nothing, [])
        Right (Just pr) ->
            Git.numstat pr.draft.base >>= \case
                Right out -> pure (Facts (Just (changedLinesOf out)) (Just pr), [])
                Left why -> pure (Facts Nothing (Just pr), ["changed lines unknown - " <> why])
