-- | Running test actions at once, for the specs that race writers.
module Concurrently (bothAtOnce) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, throwIO, try)

-- | Both on threads of their own (the suite runs threaded), a failure of either thrown.
bothAtOnce :: IO () -> IO () -> IO ()
bothAtOnce first second = do
    done <- newEmptyMVar
    _ <- forkIO (try @SomeException first >>= putMVar done)
    second
    takeMVar done >>= either throwIO pure
