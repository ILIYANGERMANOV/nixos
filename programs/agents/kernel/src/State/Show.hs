-- | Values as the 'Text' of the lines the kernel prints.
module State.Show (tshow, firstLine, timeText) where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, defaultTimeLocale, formatTime)

tshow :: (Show a) => a -> Text
tshow = Text.pack . show

-- | A tool's output cut to its first line, for a one-line why.
firstLine :: String -> Text
firstLine = Text.strip . Text.takeWhile (/= '\n') . Text.pack

{- | A time in the store's RFC 3339 s5.6 profile: UTC, uppercase @T@ and
@Z@, exactly 3 fraction digits, so 24 characters and text order is time
order ("Data.Field"'s @time@ column).
-}
timeText :: UTCTime -> Text
timeText = Text.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S.%3qZ"
