-- | JSON for the store's layers, which reach no domain module.
module Data.Json (jsonText) where

import Data.Aeson (ToJSON, encode)
import Data.ByteString.Lazy qualified as Lazy
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8)

{- | A value as one line of JSON text (RFC 8259): a string comes out quoted,
its quotes and line breaks escaped.
-}
jsonText :: (ToJSON a) => a -> Text
-- aeson encodes UTF-8, so the bytes decode whole.
jsonText = decodeUtf8 . Lazy.toStrict . encode
