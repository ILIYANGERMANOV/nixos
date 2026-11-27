{- | The wall clock every line written is stamped with, in whole milliseconds:
the store's time text holds no more ("Data.Field"), so an event reads back
as it was stamped.
-}
module Effects.Clock (
    Clock (..),
    now,
    runClockIO,
) where

import Data.Time (UTCTime (..), getCurrentTime)
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

data Clock :: Effect where
    Now :: Clock m UTCTime

type instance DispatchOf Clock = Dynamic

now :: (Clock :> es) => Eff es UTCTime
now = send Now

runClockIO :: (IOE :> es) => Eff (Clock : es) a -> Eff es a
runClockIO = interpret $ \_ -> \case
    Now -> liftIO (milliseconds <$> getCurrentTime)
  where
    milliseconds t =
        t {utctDayTime = fromInteger (floor (utctDayTime t * 1000)) / 1000}
