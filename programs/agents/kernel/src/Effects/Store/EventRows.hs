-- | A run's event rows as the store reads them: the column order lives here, beside its SQL.
module Effects.Store.EventRows (selectRows) where

import Data.Entity.Event (EventRow (..))
import Data.Text (Text)
import Database.SQLite.Simple (Connection, Only (..), query)

-- | The run's rows, in seq order, read in one statement.
selectRows :: Connection -> Text -> IO [EventRow]
selectRows conn run =
    map eventRow
        <$> query
            conn
            "SELECT run_id, seq, schema_version, type, time, session_id, head_sha, hook_digest, data FROM events WHERE run_id = ? ORDER BY seq"
            (Only run)
  where
    eventRow
        ( runId
            , n
            , schemaVersion
            , eventType
            , time
            , sessionId
            , headSha
            , hookDigest
            , payload
            ) =
            EventRow
                { runId
                , seq = n
                , schemaVersion
                , eventType
                , time
                , sessionId
                , headSha
                , hookDigest
                , payload
                }
