{- | GitHub as scripted: what @gh pr view@ does, which the shell reads with the
real parser.
-}
module Doubles.Gh (runGhScripted, printedPr) where

import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8)
import Effectful (Eff)
import Effectful.Dispatch.Dynamic (interpret)
import Effects.Gh (Gh (..))
import State.Advice (PrView (..), PullRequest (..), Readiness (..))
import State.Event (Branch (..), DraftPr (..), Url (..))

runGhScripted :: PrView -> Eff (Gh : es) a -> Eff es a
runGhScripted reply = interpret $ \_ -> \case
    PrView -> pure reply

-- | What @gh pr view --json url,baseRefName,headRefName,isDraft,state@ prints for this PR.
printedPr :: PullRequest -> PrView
printedPr pr =
    PrViewPrinted . decodeUtf8 . LBS.toStrict . encode $
        object
            [ "url" .= url
            , "baseRefName" .= base
            , "headRefName" .= branch
            , "isDraft" .= (pr.readiness == IsDraft)
            , "state" .= prState
            ]
  where
    Url url = pr.draft.url
    Branch base = pr.draft.base
    Branch branch = pr.draft.branch
    prState :: Text
    prState = case pr.readiness of
        IsDraft -> "OPEN"
        IsReady -> "OPEN"
        IsMerged -> "MERGED"
        IsClosed -> "CLOSED"
