{- | I-JSON (RFC 7493): the JSON every reader reads alike. A stopgap's value
is one, parsed here before any write; the log's integers keep to its bound.
-}
module State.Run.IJson (
    IJson,
    ijsonValue,
    IJsonRefusal (..),
    parseIJson,
    ijsonOf,
    ijsonCap,
    maxIJsonInteger,
    isNoncharacter,
    repeatedKeys,
) where

import Data.Aeson (Value (..), eitherDecodeStrictText, encode)
import Data.Aeson.Decoding.Text (textToTokens)
import Data.Aeson.Decoding.Tokens (TkArray (..), TkRecord (..), Tokens (..))
import Data.Aeson.Key (Key)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor (first)
import Data.Bits ((.&.))
import Data.ByteString.Lazy qualified as Lazy
import Data.Char (ord)
import Data.Foldable (traverse_)
import Data.Int (Int64)
import Data.Scientific (
    Scientific,
    isInteger,
    toBoundedInteger,
    toBoundedRealFloat,
 )
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text

-- | A JSON value that is I-JSON, no top-level null, within 'ijsonCap': built only by 'ijsonOf'.
newtype IJson = IJson Value
    deriving stock (Eq, Show)

ijsonValue :: IJson -> Value
ijsonValue (IJson value) = value

-- | Why a text is no stopgap value: one case per rule.
data IJsonRefusal
    = {- | No JSON text, as aeson reads it: bad syntax, text after the value,
      invalid UTF-8 or a lone surrogate, escaped or not (RFC 7493 s2.1).
      -}
      NotJson Text
    | -- | An object repeats this key, at any depth (RFC 7493 s2.3).
      RepeatedKey Key
    | -- | An integer past 2^53-1 in magnitude: not every reader reads it exactly (RFC 7493 s2.2).
      BigInteger Scientific
    | -- | A number past a double's range, too large or too small to be one (RFC 7493 s2.2).
      OutOfRange Scientific
    | -- | A key or a string holds this Unicode noncharacter (RFC 7493 s2.1).
      Noncharacter Char
    | -- | A null value: a stopgap is unset, never set to null.
      TopLevelNull
    | -- | The value's encoding takes this many octets, past 'ijsonCap'.
      OverCap Int64
    deriving stock (Eq, Show)

{- | The value of a JSON text, or the first rule it breaks. aeson reads it
first: it refuses bad syntax, trailing text and lone surrogates, but keeps
one of a repeated key and any number, which the checks after it catch.
-}
parseIJson :: Text -> Either IJsonRefusal IJson
parseIJson raw = do
    value <- first (NotJson . Text.pack) (eitherDecodeStrictText raw)
    case repeatedKeys raw of
        Right [] -> ijsonOf value
        Right (key : _) -> Left (RepeatedKey key)
        Left why -> Left (NotJson (Text.pack why))

{- | A decoded value as a stopgap's: what a repeated key would have been is
gone by now, so a text is read by 'parseIJson'; the log's own value, by this.
-}
ijsonOf :: Value -> Either IJsonRefusal IJson
ijsonOf = \case
    Null -> Left TopLevelNull
    value -> do
        valid value
        let octets = Lazy.length (encode value)
        if octets > ijsonCap then Left (OverCap octets) else Right (IJson value)

{- | The most octets a value takes as the log stores it, aeson's encoding:
the same bytes whatever spacing or escapes the text it came from had.
-}
ijsonCap :: Int64
ijsonCap = 1024

-- | The largest integer every JSON reader reads exactly: 2^53-1 (RFC 7493 s2.2).
maxIJsonInteger :: Integer
maxIJsonInteger = 2 ^ (53 :: Int) - 1

valid :: Value -> Either IJsonRefusal ()
valid = \case
    Object members ->
        traverse_
            (\(key, member) -> text (Key.toText key) >> valid member)
            (KeyMap.toList members)
    Array items -> traverse_ valid items
    String s -> text s
    Number n -> number n
    Bool _ -> Right ()
    Null -> Right ()
  where
    text = maybe (Right ()) (Left . Noncharacter) . Text.find isNoncharacter

{- | Bounded checks only: an exponent as large as @1e1000000000@ is never
expanded into the integer it names.
-}
number :: Scientific -> Either IJsonRefusal ()
number n
    | isInteger n = case toBoundedInteger @Int64 n of
        Just i | abs (toInteger i) <= maxIJsonInteger -> Right ()
        _ -> Left (BigInteger n)
    | otherwise = case toBoundedRealFloat @Double n of
        Right _ -> Right ()
        Left _ -> Left (OutOfRange n)

-- | One of Unicode's 66 noncharacters: U+FDD0..U+FDEF, and the last two of each plane.
isNoncharacter :: Char -> Bool
isNoncharacter c = (c >= '\xFDD0' && c <= '\xFDEF') || ord c .&. 0xFFFE == 0xFFFE

{- | The keys some object of this JSON text repeats, at any depth, from
aeson's token stream: a decoded 'Value' keeps one of them and hides the rest.
-}
repeatedKeys :: Text -> Either String [Key]
repeatedKeys = fmap fst . value . textToTokens
  where
    value :: Tokens k String -> Either String ([Key], k)
    value = \case
        TkLit _ rest -> Right ([], rest)
        TkText _ rest -> Right ([], rest)
        TkNumber _ rest -> Right ([], rest)
        TkArrayOpen items -> array items
        TkRecordOpen members -> record Set.empty members
        TkErr err -> Left err
    array :: TkArray k String -> Either String ([Key], k)
    array = \case
        TkItem item -> do
            (inItem, items) <- value item
            (inRest, rest) <- array items
            pure (inItem <> inRest, rest)
        TkArrayEnd rest -> Right ([], rest)
        TkArrayErr err -> Left err
    record :: Set.Set Key -> TkRecord k String -> Either String ([Key], k)
    record seen = \case
        TkPair key member -> do
            (inMember, members) <- value member
            (inRest, rest) <- record (Set.insert key seen) members
            pure ([key | Set.member key seen] <> inMember <> inRest, rest)
        TkRecordEnd rest -> Right ([], rest)
        TkRecordErr err -> Left err
