{- | Run logs in memory, each run's events as the store keeps them: one JSON
envelope per row, read and appended through the same codec, so they fail and
read as the real ones do. As in the store, a run exists once its start is
written, and events for a run never started that do not start it throw. The
lock is the single-threaded run itself.
-}
module Doubles.Log (Runs (..), runLogInMemory, rowsOf) where

import Control.Monad ((<=<))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Exception (throwIO)
import Effectful.State.Static.Local (State, get, put)
import Effects.Log (Log (..))
import State.Run.Codec (decodeLines, encodeLine)
import State.Run.Event (Envelope (..), Event (..), RunId)

{- | Each run's rows, in seq order; read-only, every lock throws, as a full
disk or a lock held past the wait fails the real store's.
-}
data Runs = Runs (Map RunId [Text]) | ReadOnly (Map RunId [Text])

runLogInMemory :: (State Runs :> es) => Eff (Log : es) a -> Eff es a
runLogInMemory = interpret $ \_ -> \case
    Exists run -> Map.member run . rowsOf <$> get
    FirstLine run -> (listToMaybe <=< Map.lookup run) . rowsOf <$> get
    Locked run decide -> do
        store <- get
        let runs = rowsOf store
            rows = Map.lookup run runs
            (new, result) = decide (decodeLines (fromMaybe [] rows))
            appended = map encodeLine new
        case (store, rows, new) of
            -- The lock is a write lock, as the real store's BEGIN IMMEDIATE is.
            (ReadOnly _, _, _) -> throwIO (userError "the run store is read-only")
            (_, _, []) -> pure ()
            (Runs _, Just old, _ : _) -> put (Runs (Map.insert run (old <> appended) runs))
            (Runs _, Nothing, Envelope {seq = 1, event = Started _} : _) -> put (Runs (Map.insert run appended runs))
            (Runs _, Nothing, _ : _) -> throwIO (userError "events for a run never started")
        pure result

-- | The rows, writable or not.
rowsOf :: Runs -> Map RunId [Text]
rowsOf = \case
    Runs runs -> runs
    ReadOnly runs -> runs
