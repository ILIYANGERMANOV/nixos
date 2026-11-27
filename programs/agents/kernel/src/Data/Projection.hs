{- | The store's projections (#552): tables of what each run's events say,
which the fold computes and the store replaces in every append's
transaction, and rebuilds whole at an open that finds them stale. Each
group of tables is a 'Projection': its name, the version of the rows
function that fills it, and its DDL. A row to write is an 'Insert'. The
table and row types are "Data.Table"'s, re-exported here.

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
    OnConflict (..),
    Value (..),
    integer,
    nullable,
    enumIn,
    enumLiteral,
    spellings,
    Projections (..),
) where

import Data.Entity.Event (EventRow)
import Data.List.NonEmpty (NonEmpty)
import Data.Table (
    Insert (..),
    OnConflict (..),
    Table (..),
    Value (..),
    indexed,
    integer,
    nullable,
    strictTable,
    uniqueOn,
 )
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)

{- | A group of projection tables: its name in @projection_versions@, the
version of its rows function, from 1, bumped by hand when the rows change,
and its tables.
-}
data Projection = Projection {name :: Text, version :: Natural, tables :: NonEmpty Table}
    deriving stock (Eq, Show)

{- | The SQL list of an enum's spellings, for a @CHECK (column IN ...)@: each
a string literal, its quotes doubled.
-}
enumIn :: [Text] -> Text
enumIn words' = "(" <> Text.intercalate ", " (map enumLiteral words') <> ")"

{- | One enum spelling as a SQL string literal, its quotes doubled: the value
a conditional @CHECK@ compares a kind or a status to.
-}
enumLiteral :: Text -> Text
enumLiteral s = "'" <> Text.replace "'" "''" s <> "'"

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
