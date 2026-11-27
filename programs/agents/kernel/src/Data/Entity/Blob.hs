{- | One row of @blobs@, flat as SQL holds it: a registered file's content,
stored once per content. No writer yet: the first is the @artifact@ event's.
-}
module Data.Entity.Blob (BlobRow (..)) where

import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.Text (Text)

data BlobRow = BlobRow
    { sha256 :: Text
    , sizeBytes :: Int64
    , content :: ByteString
    }
    deriving stock (Eq, Show)
