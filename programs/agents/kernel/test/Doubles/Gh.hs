-- | GitHub as scripted: the branch's PR, none, or why it cannot be read.
module Doubles.Gh (runGhScripted) where

import Data.Text (Text)
import Effectful (Eff)
import Effectful.Dispatch.Dynamic (interpret)
import Effects.Gh (Gh (..))
import State.Advice (PullRequest)

runGhScripted :: Either Text (Maybe PullRequest) -> Eff (Gh : es) a -> Eff es a
runGhScripted pr = interpret $ \_ -> \case
    PrView -> pure pr
