{- | One row of @runs@, flat as SQL holds it: a write-once index of a run's
first event, built from it by "Data.Payload.Event".
-}
module Data.Entity.Run (RunRow (..)) where

import Data.Text (Text)

data RunRow = RunRow
    { id :: Text
    , parentRunId :: Maybe Text
    , flow :: Text
    , notesDir :: Text
    , createdAt :: Text
    }
    deriving stock (Eq, Show)
