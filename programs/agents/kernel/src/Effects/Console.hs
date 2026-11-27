{- | The process's standard streams: stdin read whole as bytes, text out on
stdout and stderr, in the encoding the main sets on their handles, and bytes
out on stdout as given.
-}
module Effects.Console (
    Console (..),
    readStdin,
    out,
    outBytes,
    err,
    runConsoleIO,
) where

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
import Effectful.Dispatch.Dynamic (interpret, send)
import System.IO (stderr)

data Console :: Effect where
    ReadStdin :: Console m ByteString
    Out :: Text -> Console m ()
    OutBytes :: ByteString -> Console m ()
    Err :: Text -> Console m ()

type instance DispatchOf Console = Dynamic

-- | All of stdin, to its end.
readStdin :: (Console :> es) => Eff es ByteString
readStdin = send ReadStdin

-- | Text on stdout, as given: no newline is added.
out :: (Console :> es) => Text -> Eff es ()
out = send . Out

-- | Bytes on stdout, as given: a file's content, in no encoding.
outBytes :: (Console :> es) => ByteString -> Eff es ()
outBytes = send . OutBytes

-- | Text on stderr, as given: no newline is added.
err :: (Console :> es) => Text -> Eff es ()
err = send . Err

runConsoleIO :: (IOE :> es) => Eff (Console : es) a -> Eff es a
runConsoleIO = interpret $ \_ -> \case
    ReadStdin -> liftIO BS.getContents
    Out text -> liftIO (Text.putStr text)
    OutBytes bytes -> liftIO (BS.putStr bytes)
    Err text -> liftIO (Text.hPutStr stderr text)
