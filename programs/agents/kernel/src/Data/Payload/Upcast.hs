{- | How a row of an older event type reads today: the alias table renames a
type that kept its shape, and the retired set names the types that left the
domain, whose rows the fold skips. Both ship empty; a decode takes them as a
parameter, so a test can pass a table of its own.
-}
module Data.Payload.Upcast (Upcasts (..), shipped, typeOf) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)

data Upcasts = Upcasts
    { aliases :: Map Text Text
    -- ^ An old type name and the name it reads as.
    , retired :: Set Text
    }
    deriving stock (Eq, Show)

-- | What this kernel ships: no alias, no retired type yet.
shipped :: Upcasts
shipped = Upcasts {aliases = Map.empty, retired = Set.empty}

-- | The type a stored type name reads as.
typeOf :: Upcasts -> Text -> Text
typeOf upcasts stored = Map.findWithDefault stored stored upcasts.aliases
