-- | A value's 'Show' as 'Text', for the lines the kernel prints.
module State.Show (tshow) where

import Data.Text (Text)
import Data.Text qualified as Text

tshow :: (Show a) => a -> Text
tshow = Text.pack . show
