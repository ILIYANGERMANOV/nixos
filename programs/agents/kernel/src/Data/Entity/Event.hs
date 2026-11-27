{- | One row of @events@, flat as SQL holds it: text and integers, a 'Maybe'
for each nullable column. @position@ is SQLite's, never read or written.
What a row means is "Data.Payload.Event"'s; its column order is the SQL's
("Effects.Store.Events").
-}
module Data.Entity.Event (EventRow (..)) where

import Data.Int (Int64)
import Data.Text (Text)

data EventRow = EventRow
    { runId :: Text
    , seq :: Int64
    , schemaVersion :: Int64
    , eventType :: Text
    -- ^ The column @type@.
    , time :: Text
    , sessionId :: Maybe Text
    , headSha :: Maybe Text
    , hookDigest :: Maybe Text
    , payload :: Text
    -- ^ The column @data@: one JSON object.
    }
    deriving stock (Eq, Show)
