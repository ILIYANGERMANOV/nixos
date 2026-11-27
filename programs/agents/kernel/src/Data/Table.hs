{- | A store table's DDL and a row to write into it, as SQLite stores and
binds them: shared by the permanent tables ("Data.Entity") and the
projections ("Data.Projection"). Pure text and values: the store runs them.
-}
module Data.Table (
    Table (..),
    strictTable,
    indexed,
    uniqueOn,
    appendOnly,
    Insert (..),
    insertInto,
    OnConflict (..),
    Value (..),
    integer,
    nullable,
) where

import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)

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

{- | The @CREATE TRIGGER@ statements, as SQLite stores them, that abort
every UPDATE and every DELETE on the table, each naming why: a correction
is a new row, never a changed one. INSERT OR REPLACE deletes the old row
first, so the delete trigger stops it only under
@PRAGMA recursive_triggers = ON@.
-}
appendOnly :: Table -> Text -> Text -> [Text]
appendOnly table onUpdate onDelete =
    [trigger "update" "UPDATE" onUpdate, trigger "delete" "DELETE" onDelete]
  where
    trigger suffix event why =
        "CREATE TRIGGER "
            <> table.name
            <> "_no_"
            <> suffix
            <> " BEFORE "
            <> event
            <> " ON "
            <> table.name
            <> "\nBEGIN SELECT RAISE(ABORT, '"
            <> table.name
            <> " is append-only: "
            <> why
            <> "'); END"

{- | One row to write: its table, what a row already holding its key does,
and each column with its value.
-}
data Insert = Insert
    {table :: Text, onConflict :: OnConflict, values :: NonEmpty (Text, Value)}
    deriving stock (Eq, Show)

-- | A row whose key a stored row holds already fails the statement ('Abort').
insertInto :: Text -> NonEmpty (Text, Value) -> Insert
insertInto table = Insert table Abort

{- | SQLite's conflict resolution for the row: 'Abort' (its default) fails
the statement; 'DoNothing' keeps the stored row when this column's value is
taken, and still fails on a CHECK or NOT NULL, as INSERT OR IGNORE would not.
-}
data OnConflict = Abort | DoNothing Text
    deriving stock (Eq, Show)

-- | A column's value, as a STRICT table types it.
data Value = SqlText Text | SqlInteger Int64 | SqlBlob ByteString | SqlNull
    deriving stock (Eq, Ord, Show)

-- | A count or a seq, as a stored integer.
integer :: Natural -> Value
integer = SqlInteger . fromIntegral

-- | An optional column's value: 'SqlNull' when absent.
nullable :: (a -> Value) -> Maybe a -> Value
nullable = maybe SqlNull
