{- | Run logs on the in-memory disk of "Doubles.FileSystem", as bytes, read and
appended through the same codec as the files, so they fail and read as the
real ones do. The lock is the single-threaded run itself.
-}
module Doubles.Log (runLogInMemory) where

import Data.Map.Strict qualified as Map
import Doubles.FileSystem (Disk (..), absolute, existingDirectory)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.State.Static.Local (State, gets, modify)
import Effects.Log (Log (..))
import State.Codec (decodeLogBytes, encodeLines, firstLineOf)

runLogInMemory :: (State Disk :> es) => Eff (Log : es) a -> Eff es a
runLogInMemory = interpret $ \_ -> \case
    Exists path -> absolute path >>= \file -> gets @Disk (Map.member file . (.files))
    FirstLine path -> absolute path >>= \file -> gets @Disk (fmap firstLineOf . Map.lookup file . (.files))
    Locked path decide -> do
        file <- absolute path
        existingDirectory file
        bytes <- gets @Disk (Map.findWithDefault "" file . (.files))
        let (new, result) = decide (decodeLogBytes bytes)
        modify @Disk (\d -> d {files = Map.insert file (bytes <> encodeLines new) d.files})
        pure result
