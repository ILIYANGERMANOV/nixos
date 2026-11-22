-- | Wraps every spec item of the suite: hspec-discover applies 'hook' to all.
module SpecHook (hook) where

import Control.Monad ((>=>))
import System.Timeout (timeout)
import Test.Hspec (Spec, around_, expectationFailure)

{- | No item may run past a minute: a fold or property that never leaves a
loop fails here instead of hanging the suite. The slowest item takes under
2s compiled and about 15s in the interpreted ghcid session.
-}
hook :: Spec -> Spec
hook =
    around_
        ( timeout (60 * 1000000)
            >=> maybe
                (expectationFailure "timed out after 60s: a fold or property never ends")
                pure
        )
