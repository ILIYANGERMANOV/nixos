{- | What @state report@ and @state sql@ print (#552 s9, D18): a result as
tab-separated values in PostgreSQL's COPY text format, the one printer both
share. A header line of the column names, then one line per row, each line
ending in LF. NULL prints @\\N@; a backslash, backspace, form feed, LF, CR,
tab and vertical tab print as their backslash escapes, so no cell holds a
raw tab, LF or CR (IANA text/tab-separated-values) and NULL, the empty text
and the text @\\N@ print three different cells. A BLOB prints as
PostgreSQL's bytea hex, @\\x@ and lowercase hex, its backslash escaped.

<https://www.postgresql.org/docs/current/sql-copy.html> (Text Format),
<https://www.iana.org/assignments/media-types/text/tab-separated-values>.
-}
module Data.Tsv (
    Result (..),
    Cell (..),
    tsv,
) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric (showHex)

-- | A query's result: its column names, and its rows in order.
data Result = Result {header :: [Text], rows :: [[Cell]]}
    deriving stock (Eq, Show)

{- | One value of a result. An INTEGER or a REAL is the 'Text' SQLite's own
conversion spells it as, so a number prints as SQLite prints it.
-}
data Cell = Null | Text Text | Blob ByteString
    deriving stock (Eq, Show)

-- | The result as COPY text: the header line, then each row's line.
tsv :: Result -> Text
tsv result =
    Text.concat
        (map line (map (cell . Text) result.header : map (map cell) result.rows))
  where
    line cells = Text.intercalate "\t" cells <> "\n"

cell :: Cell -> Text
cell = \case
    Null -> "\\N"
    Text text -> Text.concatMap escaped text
    Blob bytes -> "\\\\x" <> Text.pack (concatMap hex (ByteString.unpack bytes))
  where
    hex byte = (if byte < 16 then ('0' :) else id) (showHex byte "")

escaped :: Char -> Text
escaped = \case
    '\\' -> "\\\\"
    '\b' -> "\\b"
    '\f' -> "\\f"
    '\n' -> "\\n"
    '\r' -> "\\r"
    '\t' -> "\\t"
    '\v' -> "\\v"
    c -> Text.singleton c
