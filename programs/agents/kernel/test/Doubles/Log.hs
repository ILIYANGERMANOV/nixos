{- | Run logs in memory, by path: read and appended through the same codec as
the files, so a log a test writes by hand reads as the real one would. The
lock is the single-threaded run itself. Unlike the file, a log here needs no
directory to exist: the directories are "Doubles.FileSystem"'s.
-}
module Doubles.Log (runLogInMemory) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff)
import Effectful.Dispatch.Dynamic (reinterpret)
import Effectful.State.Static.Local (gets, runState, state)
import Effects.Log (Log (..))
import State.Codec (decodeLog, encodeLine)

-- | The run returns every log after it.
runLogInMemory :: Map FilePath Text -> Eff (Log : es) a -> Eff es (a, Map FilePath Text)
runLogInMemory logs = reinterpret (runState logs) $ \_ -> \case
    Exists path -> gets @(Map FilePath Text) (Map.member path)
    FirstLine path -> gets @(Map FilePath Text) (fmap (Text.takeWhile (/= '\n')) . Map.lookup path)
    Locked path decide -> state $ \files ->
        let text = Map.findWithDefault "" path files
            (new, result) = decide (decodeLog text)
         in (result, Map.insert path (text <> foldMap ((<> "\n") . encodeLine) new) files)
