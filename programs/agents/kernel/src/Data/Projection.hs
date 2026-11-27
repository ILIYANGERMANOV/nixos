{- | The store's projections (#552): tables of what each run's events say,
which the fold computes and the store replaces in every append's
transaction, and rebuilds whole at an open that finds them stale. Each
group of tables is a 'Projection': its name, the version of the rows
function that fills it, and its DDL. A row to write is an 'Insert'.

Nothing here names a domain type: the store reads this module, and the
rows functions over the fold live in "Data.Projection.*".
-}
module Data.Projection (
    Projection (..),
    Table (..),
    strictTable,
    indexed,
    uniqueOn,
    Insert (..),
    Value (..),
    integer,
    nullable,
    enumIn,
    spellings,
    Projections (..),
) where

import Data.Entity.Event (EventRow)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)

{- | A group of projection tables: its name in @projection_versions@, the
version of its rows function, from 1, bumped by hand when the rows change,
and its tables.
-}
data Projection = Projection {name :: Text, version :: Natural, tables :: NonEmpty Table}
    deriving stock (Eq, Show)

{- | A table: its name, its @CREATE TABLE@ statement exactly as SQLite
stores it in @sqlite_schema.sql@, comments kept and no @;@, and its indexes'
@CREATE INDEX@ statements, made after it. Open compares the stored text byte
for byte, so each statement says only what SQLite keeps.
-}
data Table = Table {name :: Text, ddl :: Text, indexes :: [Text]}
    deriving stock (Eq, Show)

{- | A STRICT table of this name, its lines between the parentheses, each
indented as it should be stored.
-}
strictTable :: Text -> [Text] -> Table
strictTable name body =
    Table
        { name
        , ddl =
            Text.intercalate "\n" (("CREATE TABLE " <> name <> " (") : body <> [") STRICT"])
        , indexes = []
        }

-- | The table with an index on these columns, named after them as sqlstyle.guide does.
indexed :: [Text] -> Table -> Table
indexed columns table =
    table
        { indexes =
            table.indexes
                <> [ "CREATE INDEX "
                        <> Text.intercalate "_" (table.name : columns)
                        <> "_idx ON "
                        <> table.name
                        <> " ("
                        <> Text.intercalate ", " columns
                        <> ")"
                   ]
        }

{- | The table with a unique index of this name on these expressions, for a
key an expression states, such as one whose NULL counts as one value.
-}
uniqueOn :: Text -> [Text] -> Table -> Table
uniqueOn index expressions table =
    table
        { indexes =
            table.indexes
                <> [ "CREATE UNIQUE INDEX "
                        <> index
                        <> " ON "
                        <> table.name
                        <> " ("
                        <> Text.intercalate ", " expressions
                        <> ")"
                   ]
        }

-- | One row to write: its table, and each column with its value.
data Insert = Insert {table :: Text, values :: NonEmpty (Text, Value)}
    deriving stock (Eq, Show)

-- | A column's value, as a STRICT table types it.
data Value = SqlText Text | SqlInteger Int64 | SqlNull
    deriving stock (Eq, Ord, Show)

-- | A count or a seq, which every stored integer here is.
integer :: Natural -> Value
integer = SqlInteger . fromIntegral

-- | An optional column's value: 'SqlNull' when absent.
nullable :: (a -> Value) -> Maybe a -> Value
nullable = maybe SqlNull

{- | The SQL list of an enum's spellings, for a @CHECK (column IN ...)@: each
a string literal, its quotes doubled.
-}
enumIn :: [Text] -> Text
enumIn words' =
    "(" <> Text.intercalate ", " [quoted s | s <- words'] <> ")"
  where
    quoted s = "'" <> Text.replace "'" "''" s <> "'"

-- | An enum's spellings, from its DB spelling function: a CHECK's list.
spellings :: (Enum a, Bounded a) => (a -> Text) -> Text
spellings spelling = enumIn (map spelling [minBound .. maxBound])

{- | What the store needs to keep the projections: every projection, the
@CREATE VIEW@ statements of the views over them, each as SQLite stores it
and made after every table, and the rows of one run computed from its event
rows, in seq order. A run whose log the fold does not take has none.
-}
data Projections = Projections
    { projections :: [Projection]
    , views :: [Text]
    , refold :: [EventRow] -> [Insert]
    }
