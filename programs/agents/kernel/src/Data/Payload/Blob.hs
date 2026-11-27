{- | A domain 'Blob' as a @blobs@ row and back. The row's key and size are
its content's, never given apart from it, so a blob's key is the hash of its
content by construction.
-}
module Data.Payload.Blob (blobRow, blobOf) where

import Data.ByteString qualified as ByteString
import Data.Entity.Blob (BlobRow (..))
import Data.Field qualified as Field
import State.Artifact (Blob (..), blobKey)

blobRow :: Blob -> BlobRow
blobRow blob@(Blob bytes) =
    BlobRow
        { sha256 = Field.encode Field.sha256 (blobKey blob)
        , sizeBytes = fromIntegral (ByteString.length bytes)
        , content = bytes
        }

{- | The row's blob, when its key is the digest of its content and its size
the content's: a row that disagrees is none this kernel wrote.
-}
blobOf :: BlobRow -> Maybe Blob
blobOf row
    | blobRow blob == row = Just blob
    | otherwise = Nothing
  where
    blob = Blob row.content
