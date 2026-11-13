{- | Files and directories other than the log, which "Effects.Log" owns: the
step table, the notes pointer, the notes dir, and the directory a hook runs in.
Split read from write, so that code which only reads cannot change the disk.
-}
module Effects.FileSystem (
    RoFileSystem (..),
    WrFileSystem (..),
    readBytes,
    readText,
    makeAbsolute,
    inDirectory,
    writeText,
    createDirectory,
    runFileSystemIO,
) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text.IO qualified as Text
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret, localSeqUnliftIO, send)
import System.Directory (createDirectoryIfMissing, doesFileExist, withCurrentDirectory)
import System.Directory qualified as Directory

data RoFileSystem :: Effect where
    ReadBytes :: FilePath -> RoFileSystem m ByteString
    ReadText :: FilePath -> RoFileSystem m (Maybe Text)
    MakeAbsolute :: FilePath -> RoFileSystem m FilePath
    InDirectory :: FilePath -> m a -> RoFileSystem m a

data WrFileSystem :: Effect where
    WriteText :: FilePath -> Text -> WrFileSystem m ()
    CreateDirectory :: FilePath -> WrFileSystem m ()

type instance DispatchOf RoFileSystem = Dynamic
type instance DispatchOf WrFileSystem = Dynamic

-- | A file's bytes; a missing file throws.
readBytes :: (RoFileSystem :> es) => FilePath -> Eff es ByteString
readBytes = send . ReadBytes

-- | A file's text in the locale's encoding, 'Nothing' when it does not exist.
readText :: (RoFileSystem :> es) => FilePath -> Eff es (Maybe Text)
readText = send . ReadText

-- | The path against the current directory.
makeAbsolute :: (RoFileSystem :> es) => FilePath -> Eff es FilePath
makeAbsolute = send . MakeAbsolute

-- | Run the action with this as the current directory, which git and gh read.
inDirectory :: (RoFileSystem :> es) => FilePath -> Eff es a -> Eff es a
inDirectory dir = send . InDirectory dir

-- | Replace a file's text, in the locale's encoding.
writeText :: (WrFileSystem :> es) => FilePath -> Text -> Eff es ()
writeText path = send . WriteText path

-- | The directory and its parents, those missing.
createDirectory :: (WrFileSystem :> es) => FilePath -> Eff es ()
createDirectory = send . CreateDirectory

runFileSystemIO :: (IOE :> es) => Eff (WrFileSystem : RoFileSystem : es) a -> Eff es a
runFileSystemIO = runRoFileSystemIO . runWrFileSystemIO

runRoFileSystemIO :: (IOE :> es) => Eff (RoFileSystem : es) a -> Eff es a
runRoFileSystemIO = interpret $ \env -> \case
    ReadBytes path -> liftIO (BS.readFile path)
    ReadText path ->
        liftIO $
            doesFileExist path >>= \case
                False -> pure Nothing
                True -> Just <$> Text.readFile path
    MakeAbsolute path -> liftIO (Directory.makeAbsolute path)
    InDirectory dir act -> localSeqUnliftIO env $ \unlift -> withCurrentDirectory dir (unlift act)

runWrFileSystemIO :: (IOE :> es) => Eff (WrFileSystem : es) a -> Eff es a
runWrFileSystemIO = interpret $ \_ -> \case
    WriteText path text -> liftIO (Text.writeFile path text)
    CreateDirectory path -> liftIO (createDirectoryIfMissing True path)
