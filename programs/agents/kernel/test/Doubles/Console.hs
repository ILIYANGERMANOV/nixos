{- | The standard streams of one process: stdin given up front and read once,
as a pipe is, and what it wrote to stdout and stderr.
-}
module Doubles.Console (Streams (..), runConsoleCaptured) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Effectful (Eff)
import Effectful.Dispatch.Dynamic (reinterpret)
import Effectful.State.Static.Local (modify, runState, state)
import Effects.Console (Console (..))

data Streams = Streams {stdin :: ByteString, stdout :: Text, stderr :: Text}

-- | The streams after the run: stdin what is left unread.
runConsoleCaptured :: ByteString -> Eff (Console : es) a -> Eff es (a, Streams)
runConsoleCaptured input = reinterpret (runState (Streams input "" "")) $ \_ -> \case
    ReadStdin -> state @Streams (\s -> (s.stdin, s {stdin = ""}))
    Out text -> modify @Streams (\s -> s {stdout = s.stdout <> text})
    Err text -> modify @Streams (\s -> s {stderr = s.stderr <> text})
