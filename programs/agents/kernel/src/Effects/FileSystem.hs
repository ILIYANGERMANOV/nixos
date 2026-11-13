{- | Files and directories other than the log, which "Effects.Log" owns: the
step table, the notes pointer, the notes dir, and the directory a hook runs in.
-}
module Effects.FileSystem (
    FileSystem (..),
    readBytes,
    readText,
    writeText,
    makeAbsolute,
    createDirectory,
    inDirectory,
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

data FileSystem :: Effect where
    ReadBytes :: FilePath -> FileSystem m ByteString
    ReadText :: FilePath -> FileSystem m (Maybe Text)
    WriteText :: FilePath -> Text -> FileSystem m ()
    MakeAbsolute :: FilePath -> FileSystem m FilePath
    CreateDirectory :: FilePath -> FileSystem m ()
    InDirectory :: FilePath -> m a -> FileSystem m a

type instance DispatchOf FileSystem = Dynamic

-- | A file's bytes; a missing file throws.
readBytes :: (FileSystem :> es) => FilePath -> Eff es ByteString
readBytes = send . ReadBytes

-- | A file's text in the locale's encoding, 'Nothing' when it does not exist.
readText :: (FileSystem :> es) => FilePath -> Eff es (Maybe Text)
readText = send . ReadText

-- | Replace a file's text, in the locale's encoding.
writeText :: (FileSystem :> es) => FilePath -> Text -> Eff es ()
writeText path = send . WriteText path

-- | The path against the current directory.
makeAbsolute :: (FileSystem :> es) => FilePath -> Eff es FilePath
makeAbsolute = send . MakeAbsolute

-- | The directory and its parents, those missing.
createDirectory :: (FileSystem :> es) => FilePath -> Eff es ()
createDirectory = send . CreateDirectory

-- | Run the action with this as the current directory, which git and gh read.
inDirectory :: (FileSystem :> es) => FilePath -> Eff es a -> Eff es a
inDirectory dir = send . InDirectory dir

runFileSystemIO :: (IOE :> es) => Eff (FileSystem : es) a -> Eff es a
runFileSystemIO = interpret $ \env -> \case
    ReadBytes path -> liftIO (BS.readFile path)
    ReadText path ->
        liftIO $
            doesFileExist path >>= \case
                False -> pure Nothing
                True -> Just <$> Text.readFile path
    WriteText path text -> liftIO (Text.writeFile path text)
    MakeAbsolute path -> liftIO (Directory.makeAbsolute path)
    CreateDirectory path -> liftIO (createDirectoryIfMissing True path)
    InDirectory dir act -> localSeqUnliftIO env $ \unlift -> withCurrentDirectory dir (unlift act)
