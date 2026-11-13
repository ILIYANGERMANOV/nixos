{- | A disk in memory: files, the directories that hold them, and the current
directory relative paths resolve against. It fails as the real one does: a
missing file or directory throws 'IOException'.
-}
module Doubles.FileSystem (Disk (..), runFileSystemInMemory) where

import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import Effectful (Eff)
import Effectful.Dispatch.Dynamic (localSeqUnlift, reinterpret)
import Effectful.Exception (finally, throwIO)
import Effectful.State.Static.Local (State, get, gets, modify, runState)
import Effects.FileSystem (FileSystem (..))
import System.FilePath (normalise, takeDirectory, (</>))
import System.IO.Error (IOErrorType, doesNotExistErrorType, mkIOError, userErrorType)

-- | Paths in it are absolute and normalised.
data Disk = Disk {files :: Map FilePath ByteString, dirs :: Set FilePath, cwd :: FilePath}

-- | The run returns the disk after it.
runFileSystemInMemory :: Disk -> Eff (FileSystem : es) a -> Eff es (a, Disk)
runFileSystemInMemory disk = reinterpret (runState disk) $ \env -> \case
    ReadBytes path -> absolute path >>= readFile'
    ReadText path ->
        absolute path >>= \file ->
            gets @Disk (Map.member file . (.files)) >>= \case
                False -> pure Nothing
                True -> readFile' file >>= either (const (failure userErrorType "invalid byte sequence" file)) (pure . Just) . decodeUtf8'
    WriteText path text -> do
        file <- absolute path
        inDir file
        modify @Disk (\d -> d {files = Map.insert file (encodeUtf8 text) d.files})
    MakeAbsolute path -> absolute path
    CreateDirectory path -> absolute path >>= \dir -> modify @Disk (\d -> d {dirs = d.dirs <> Set.fromList (ancestors dir)})
    InDirectory path act -> do
        dir <- absolute path
        gets @Disk (Set.member dir . (.dirs)) >>= \case
            False -> failure doesNotExistErrorType "withCurrentDirectory" dir
            True -> do
                before <- get @Disk
                modify @Disk (\d -> d {cwd = dir})
                localSeqUnlift env (\unlift -> unlift act) `finally` modify @Disk (\d -> d {cwd = before.cwd})
  where
    absolute path = gets @Disk (\d -> normalise (d.cwd </> path))
    readFile' file = gets @Disk (Map.lookup file . (.files)) >>= maybe (failure doesNotExistErrorType "openFile" file) pure
    inDir file =
        gets @Disk (Set.member (takeDirectory file) . (.dirs)) >>= \case
            True -> pure ()
            False -> failure doesNotExistErrorType "openFile" file

failure :: IOErrorType -> String -> FilePath -> Eff (State Disk : es) a
failure kind what file = throwIO (mkIOError kind what Nothing (Just file))

-- | The directory and each above it, up to the root.
ancestors :: FilePath -> [FilePath]
ancestors dir = case takeDirectory dir of
    parent | parent == dir -> [dir]
    parent -> dir : ancestors parent
