-- | Entropy drawn in order from a given stream of bytes, each byte once.
module Doubles.Random (runRandomFixed) where

import Data.ByteString qualified as BS
import Data.Word (Word8)
import Effectful (Eff)
import Effectful.Dispatch.Dynamic (reinterpret)
import Effectful.State.Static.Local (runState, state)
import Effects.Random (Random (..))

-- | The stream is infinite, as @/dev/urandom@ is; the run returns what is left of it.
runRandomFixed :: [Word8] -> Eff (Random : es) a -> Eff es (a, [Word8])
runRandomFixed bytes = reinterpret (runState bytes) $ \_ -> \case
    RandomBytes n -> state @[Word8] (\left -> let (drawn, rest) = splitAt n left in (BS.pack drawn, rest))
