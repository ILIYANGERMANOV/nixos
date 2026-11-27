{- | One row of @blobs@, flat as SQL holds it: a registered file's content,
stored once per content. What a row means is "Data.Payload.Blob"'s. Beside
it the table's DDL, its append-only triggers and its row's 'Insert'.
-}
module Data.Entity.Blob (BlobRow (..), table, triggers, blobInsert) where

import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Table (
    Insert (..),
    OnConflict (..),
    Table,
    Value (..),
    appendOnly,
    strictTable,
 )
import Data.Text (Text)

data BlobRow = BlobRow
    { sha256 :: Text
    , sizeBytes :: Int64
    , content :: ByteString
    }
    deriving stock (Eq, Show)

table :: Table
table =
    strictTable
        "blobs"
        [ "  -- The content of registered files, stored once per content. Append-only."
        , "  -- An artifact event names a file by path and sha256. The file's bytes live here"
        , "  -- when the writer snapshots them (files up to 1048576 bytes; the cap lives in the writer)."
        , ""
        , "  -- SHA-256 of content: 64 lowercase hex. The OCI digest without its sha256: prefix."
        , "  sha256     TEXT    NOT NULL PRIMARY KEY"
        , "             CONSTRAINT blobs_sha256_format CHECK (length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'),"
        , "  -- The length of content in bytes. OCI size. Kept beside content for the OCI mapping."
        , "  size_bytes INTEGER NOT NULL,"
        , "  -- The file's bytes, as read once at registration. OCI data."
        , "  content    BLOB    NOT NULL,"
        , "  CONSTRAINT blobs_size_bytes_matches_content CHECK (size_bytes = length(content))"
        ]

triggers :: [Text]
triggers =
    appendOnly table "new content is a new row" "content is never deleted"

{- | A blob already stored is kept as it is: its key is its content's
digest, so the content is the same. Not INSERT OR REPLACE: a replace
deletes first, which the delete trigger forbids.
-}
blobInsert :: BlobRow -> Insert
blobInsert row =
    Insert
        "blobs"
        (DoNothing "sha256")
        ( ("sha256", SqlText row.sha256)
            :| [ ("size_bytes", SqlInteger row.sizeBytes)
               , ("content", SqlBlob row.content)
               ]
        )
