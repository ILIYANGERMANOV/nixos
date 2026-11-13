{- | A run's log, @events.jsonl@: its first line read without a lock, and every
write one read-decide-append under an exclusive lock, so two writers never
number a line alike.
-}
module Effects.Log (
    Log (..),
    exists,
    firstLine,
    locked,
    runLogIO,
) where

import Data.ByteString qualified as BS
import Data.Text (Text)
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import GHC.IO.Handle.Lock (LockMode (ExclusiveLock), hLock)
import State.Run.Codec (LogError, decodeLogBytes, encodeLines, firstLineBytes, firstLineOf)
import State.Run.Event (Envelope)
import System.Directory (doesFileExist)
import System.IO (IOMode (ReadMode, ReadWriteMode), SeekMode (SeekFromEnd), hFileSize, hSeek, withBinaryFile)

data Log :: Effect where
    Exists :: FilePath -> Log m Bool
    FirstLine :: FilePath -> Log m (Maybe Text)
    Locked :: FilePath -> (Either LogError [Envelope] -> ([Envelope], a)) -> Log m a

type instance DispatchOf Log = Dynamic

exists :: (Log :> es) => FilePath -> Eff es Bool
exists = send . Exists

-- | The log's first line, read leniently, if the file exists.
firstLine :: (Log :> es) => FilePath -> Eff es (Maybe Text)
firstLine = send . FirstLine

{- | The log, created if absent, locked for one decision: @decide@ gets every
line so far, or the first it cannot read, and returns the lines to append.
The lock lasts until the lines are written. Its directory must exist.
-}
locked :: (Log :> es) => FilePath -> (Either LogError [Envelope] -> ([Envelope], a)) -> Eff es a
locked path = send . Locked path

runLogIO :: (IOE :> es) => Eff (Log : es) a -> Eff es a
runLogIO = interpret $ \_ -> \case
    Exists path -> liftIO (doesFileExist path)
    FirstLine path ->
        liftIO $
            doesFileExist path >>= \case
                False -> pure Nothing
                True -> Just . firstLineOf <$> withBinaryFile path ReadMode (`BS.hGet` firstLineBytes)
    Locked path decide -> liftIO . withBinaryFile path ReadWriteMode $ \h -> do
        hLock h ExclusiveLock
        size <- hFileSize h
        bytes <- BS.hGet h (fromIntegral size)
        let (new, result) = decide (decodeLogBytes bytes)
        hSeek h SeekFromEnd 0
        -- One write, so a reader without the lock never sees half a call's lines.
        BS.hPut h (encodeLines new)
        pure result
