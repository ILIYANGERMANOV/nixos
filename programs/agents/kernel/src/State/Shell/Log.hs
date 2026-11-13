{- | Where a worktree's run lives and how its log is written: a pointer file
in the git dir names the notes dir, which holds @events.jsonl@. Every write
is one read-decide-append under an exclusive lock, so two writers never
number a line alike.
-}
module State.Shell.Log (
    readPointer,
    writePointer,
    locked,
) where

import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import GHC.IO.Handle.Lock (LockMode (ExclusiveLock), hLock)
import State.Codec (LineError (..), LogError (..), decodeLog, encodeLine)
import State.Event (Envelope)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO (IOMode (ReadWriteMode), SeekMode (SeekFromEnd), hFileSize, hSeek, withBinaryFile)

-- | The notes dir the worktree's run keeps, if a run was started here.
readPointer :: FilePath -> IO (Maybe FilePath)
readPointer gitDir = do
    let pointer = pointerOf gitDir
    exists <- doesFileExist pointer
    if exists
        then Just . Text.unpack . Text.strip . Text.pack <$> readFile pointer
        else pure Nothing

writePointer :: FilePath -> FilePath -> IO ()
writePointer gitDir notes = writeFile (pointerOf gitDir) (notes <> "\n")

pointerOf :: FilePath -> FilePath
pointerOf gitDir = gitDir </> "state-notes"

{- | The log, created if absent, locked for one decision: @decide@ gets every
line so far, or the first it cannot read, and returns the lines to append.
The lock lasts until the lines are written.
-}
locked :: FilePath -> (Either LogError [Envelope] -> IO ([Envelope], a)) -> IO a
locked path decide = withBinaryFile path ReadWriteMode $ \h -> do
    hLock h ExclusiveLock
    size <- hFileSize h
    bytes <- BS.hGet h (fromIntegral size)
    (new, result) <- decide (decoded bytes)
    hSeek h SeekFromEnd 0
    -- One write, so a reader without the lock never sees half a call's lines.
    BS.hPut h (encodeUtf8 (foldMap ((<> "\n") . encodeLine) new))
    pure result

decoded :: BS.ByteString -> Either LogError [Envelope]
decoded bytes = case decodeUtf8' bytes of
    Left _ -> Left (LogError 0 (Malformed ("the log is not UTF-8" :: Text)))
    Right text -> decodeLog text
