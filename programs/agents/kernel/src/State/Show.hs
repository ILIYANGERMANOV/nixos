-- | Values as the 'Text' of the lines the kernel prints.
module State.Show (tshow, firstLine) where

import Data.Text (Text)
import Data.Text qualified as Text

tshow :: (Show a) => a -> Text
tshow = Text.pack . show

-- | A tool's output cut to its first line, for a one-line why.
firstLine :: String -> Text
firstLine = Text.strip . Text.takeWhile (/= '\n') . Text.pack
