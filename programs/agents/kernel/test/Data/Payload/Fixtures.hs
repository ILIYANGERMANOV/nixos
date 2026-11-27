-- | Upcasts of a kernel that renamed and retired a type, which this one never did.
module Data.Payload.Fixtures (retiring) where

import Data.Map.Strict qualified as Map
import Data.Payload.Upcast (Upcasts (..))
import Data.Set qualified as Set

-- | @refusal@ reads as @refused@, and @legacy.note@ left the domain.
retiring :: Upcasts
retiring =
    Upcasts
        { aliases = Map.singleton "refusal" "refused"
        , retired = Set.singleton "legacy.note"
        }
