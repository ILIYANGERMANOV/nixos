-- | The projection rows a store holds, read back past the kernel, for the specs that compare them.
module Effects.Store.Projected (Row, projectionRows, inserted, projectionTables) where

import Data.Foldable (toList)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Projection (Insert (..), Projection (..), Table (..), Value (..))
import Data.Projection.Registry (projections)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Database.SQLite.Simple (
    Connection,
    Only (..),
    Query (..),
    SQLData (..),
    query,
    query_,
 )

-- | A row: its table, and each column's value.
type Row = (Text, Map Text Value)

-- | Every projection table's name.
projectionTables :: [Text]
projectionTables = [t.name | p <- projections, t <- toList p.tables]

-- | Every row of every projection table.
projectionRows :: Connection -> IO (Set Row)
projectionRows conn = Set.fromList . concat <$> traverse rowsOf projectionTables
  where
    rowsOf table = do
        columns <-
            map fromOnly
                <$> query conn "SELECT name FROM pragma_table_info(?) ORDER BY cid" (Only table)
        values <- query_ conn (Query ("SELECT * FROM " <> table)) :: IO [[SQLData]]
        pure [(table, Map.fromList (zip columns (map value row))) | row <- values]
    value = \case
        SQLText t -> SqlText t
        SQLInteger i -> SqlInteger i
        SQLNull -> SqlNull
        other -> error ("a projection holds no " <> show other)

-- | The rows these inserts write.
inserted :: [Insert] -> Set Row
inserted inserts = Set.fromList [(i.table, Map.fromList (toList i.values)) | i <- inserts]
