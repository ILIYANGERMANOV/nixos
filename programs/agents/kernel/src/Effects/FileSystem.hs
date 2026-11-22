{- | Files and directories other than the log, which "Effects.Log" owns: the
step table, the notes pointer, the notes dir, the hooks' bindings and the
directory a hook runs in.
Split read from write, so that code which only reads cannot change the disk.
-}
module Effects.FileSystem (
    RoFileSystem (..),
    WrFileSystem (..),
    readBytes,
    readText,
    listDirectory,
    inDirectory,
    writeText,
    writeTextAtomic,
    removeFile,
    createDirectory,
    runFileSystemIO,
) where

import Control.Exception (bracketOnError, catchJust)
import Control.Monad (guard)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text.IO qualified as Text
import Effectful (
    Dispatch (Dynamic),
    DispatchOf,
    Eff,
    Effect,
    IOE,
    liftIO,
    (:>),
 )
import Effectful.Dispatch.Dynamic (interpret, localSeqUnliftIO, send)
import System.Directory (
    createDirectoryIfMissing,
    doesFileExist,
    renameFile,
    withCurrentDirectory,
 )
import System.Directory qualified as Directory
import System.FilePath (takeDirectory, takeFileName)
import System.IO (hClose, openTempFile)
import System.IO.Error (isDoesNotExistError)

data RoFileSystem :: Effect where
    ReadBytes :: FilePath -> RoFileSystem m ByteString
    ReadText :: FilePath -> RoFileSystem m (Maybe Text)
    ListDirectory :: FilePath -> RoFileSystem m [FilePath]
    InDirectory :: FilePath -> m a -> RoFileSystem m a

data WrFileSystem :: Effect where
    WriteText :: FilePath -> Text -> WrFileSystem m ()
    WriteTextAtomic :: FilePath -> Text -> WrFileSystem m ()
    RemoveFile :: FilePath -> WrFileSystem m ()
    CreateDirectory :: FilePath -> WrFileSystem m ()

type instance DispatchOf RoFileSystem = Dynamic
type instance DispatchOf WrFileSystem = Dynamic

-- | A file's bytes; a missing file throws.
readBytes :: (RoFileSystem :> es) => FilePath -> Eff es ByteString
readBytes = send . ReadBytes

-- | A file's text in the locale's encoding, 'Nothing' when it does not exist.
readText :: (RoFileSystem :> es) => FilePath -> Eff es (Maybe Text)
readText = send . ReadText

-- | The names in a directory, none when it does not exist.
listDirectory :: (RoFileSystem :> es) => FilePath -> Eff es [FilePath]
listDirectory = send . ListDirectory

-- | Run the action with this as the current directory, which git and gh read.
inDirectory :: (RoFileSystem :> es) => FilePath -> Eff es a -> Eff es a
inDirectory dir = send . InDirectory dir

-- | Replace a file's text, in the locale's encoding.
writeText :: (WrFileSystem :> es) => FilePath -> Text -> Eff es ()
writeText path = send . WriteText path

{- | Replace a file's text as 'writeText' does, but whole or not at all: a
reader running at the same time sees the old text or the new, never part.
-}
writeTextAtomic :: (WrFileSystem :> es) => FilePath -> Text -> Eff es ()
writeTextAtomic path = send . WriteTextAtomic path

-- | Remove a file; one already absent is no failure.
removeFile :: (WrFileSystem :> es) => FilePath -> Eff es ()
removeFile = send . RemoveFile

-- | The directory and its parents, those missing.
createDirectory :: (WrFileSystem :> es) => FilePath -> Eff es ()
createDirectory = send . CreateDirectory

runFileSystemIO ::
    (IOE :> es) => Eff (WrFileSystem : RoFileSystem : es) a -> Eff es a
runFileSystemIO = runRoFileSystemIO . runWrFileSystemIO

runRoFileSystemIO :: (IOE :> es) => Eff (RoFileSystem : es) a -> Eff es a
runRoFileSystemIO = interpret $ \env -> \case
    ReadBytes path -> liftIO (BS.readFile path)
    ReadText path ->
        liftIO $
            doesFileExist path >>= \case
                False -> pure Nothing
                True -> Just <$> Text.readFile path
    ListDirectory dir -> liftIO (orIfAbsent [] (Directory.listDirectory dir))
    InDirectory dir act -> localSeqUnliftIO env $ \unlift -> withCurrentDirectory dir (unlift act)

runWrFileSystemIO :: (IOE :> es) => Eff (WrFileSystem : es) a -> Eff es a
runWrFileSystemIO = interpret $ \_ -> \case
    WriteText path text -> liftIO (Text.writeFile path text)
    -- A temp file in the same directory, so the rename stays on one file system.
    WriteTextAtomic path text ->
        liftIO $
            bracketOnError
                (openTempFile (takeDirectory path) (takeFileName path <> ".tmp"))
                (\(temp, handle) -> hClose handle >> Directory.removeFile temp)
                ( \(temp, handle) -> Text.hPutStr handle text >> hClose handle >> renameFile temp path
                )
    RemoveFile path -> liftIO (orIfAbsent () (Directory.removeFile path))
    CreateDirectory path -> liftIO (createDirectoryIfMissing True path)

-- | The action's result, or this when the path it names does not exist.
orIfAbsent :: a -> IO a -> IO a
orIfAbsent absent act = catchJust (guard . isDoesNotExistError) act (const (pure absent))
