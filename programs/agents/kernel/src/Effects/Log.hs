{- | A run's log, by its id: its first event read without the write lock, and
every write one read-decide-append under it, so two writers never number an
event alike. The real one is the kernel's run store ("Effects.Store").
-}
module Effects.Log (
    Log (..),
    exists,
    firstLine,
    locked,
    children,
    inNotes,
    runLogIO,
) where

import Control.Exception (handle, throwIO)
import Data.Text (Text)
import Database.SQLite.Simple (SQLError)
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
import Effects.Environment (Environment, lookupEnv)
import Effects.Store (Durability, Store, withStore)
import Effects.Store qualified as Store
import State.Protocol.Binding (runStore)
import State.Run.Codec (LogError)
import State.Run.Event (Envelope, RunId)

data Log :: Effect where
    Exists :: RunId -> Log m Bool
    FirstLine :: RunId -> Log m (Maybe Text)
    Locked :: RunId -> (Either LogError [Envelope] -> ([Envelope], a)) -> Log m a
    Children :: RunId -> Log m [RunId]
    InNotes :: FilePath -> Log m [RunId]

type instance DispatchOf Log = Dynamic

-- | Whether the run was started.
exists :: (Log :> es) => RunId -> Eff es Bool
exists = send . Exists

-- | The run's first event, as written, if it was started.
firstLine :: (Log :> es) => RunId -> Eff es (Maybe Text)
firstLine = send . FirstLine

{- | The run's log, locked for one decision: @decide@ gets every event so far,
or the first it cannot read, and returns the events to append. The lock lasts
until they are written. Events for a run never started that do not start it
throw.
-}
locked ::
    (Log :> es) =>
    RunId -> (Either LogError [Envelope] -> ([Envelope], a)) -> Eff es a
locked run = send . Locked run

-- | The runs started as children of this one, oldest first.
children :: (Log :> es) => RunId -> Eff es [RunId]
children = send . Children

-- | The runs started in this notes dir, oldest first.
inNotes :: (Log :> es) => FilePath -> Eff es [RunId]
inNotes = send . InNotes

{- | The log in the run store the environment names ('runStore'), opened for
each operation at this durability. A store error, such as a lock still held after the wait, or
no store at all, throws an 'IOException': an outage the shell tells.
-}
runLogIO ::
    (Environment :> es, IOE :> es) => Durability -> Eff (Log : es) a -> Eff es a
runLogIO durability = interpret $ \_ op -> do
    path <- runStore <$> lookupEnv "XDG_STATE_HOME" <*> lookupEnv "HOME"
    liftIO . asIOError $ case path of
        Nothing ->
            throwIO
                (userError "no run store: neither XDG_STATE_HOME nor HOME is an absolute path")
        Just db -> withStore durability db (onStore op)
  where
    asIOError =
        handle (\(e :: SQLError) -> throwIO (userError ("the run store: " <> show e)))

onStore :: Log m a -> Store -> IO a
onStore op store = case op of
    Exists run -> Store.exists store run
    FirstLine run -> Store.firstEvent store run
    Locked run decide -> Store.locked store run decide
    Children run -> Store.children store run
    InNotes notes -> Store.inNotes store notes
