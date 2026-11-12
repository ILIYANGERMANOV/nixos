{- | How much work a run does. Quality is the user's knob, spelled on the wire
as a brief's @Quality: <mode>@ line.
-}
module State.Mode (
    Quality (..),
    qualityName,
    parseQuality,
) where

import Data.Text (Text)

{- | No 'Ord' on purpose: the mode order of #351 is its own definition, not
the order the constructors happen to be written in.
-}
data Quality = Poc | Balanced | Max
    deriving stock (Eq, Show, Enum, Bounded)

-- | The wire name, as a brief and the Quality table spell it.
qualityName :: Quality -> Text
qualityName = \case
    Poc -> "POC"
    Balanced -> "Balanced"
    Max -> "Max"

-- | Exact spelling only: a misspelled mode is not silently a default.
parseQuality :: Text -> Maybe Quality
parseQuality name = lookup name [(qualityName quality, quality) | quality <- [minBound .. maxBound]]
