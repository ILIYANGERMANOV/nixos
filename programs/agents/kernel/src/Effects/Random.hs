-- | The kernel's entropy, which a new run's id is drawn from.
module Effects.Random (
    Random (..),
    randomBytes,
    runRandomIO,
) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import System.IO (IOMode (ReadMode), withBinaryFile)

data Random :: Effect where
    RandomBytes :: Int -> Random m ByteString

type instance DispatchOf Random = Dynamic

-- | This many random bytes.
randomBytes :: (Random :> es) => Int -> Eff es ByteString
randomBytes = send . RandomBytes

runRandomIO :: (IOE :> es) => Eff (Random : es) a -> Eff es a
runRandomIO = interpret $ \_ -> \case
    RandomBytes n -> liftIO (withBinaryFile "/dev/urandom" ReadMode (`BS.hGet` n))
