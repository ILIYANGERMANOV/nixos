{- | Logs written by an earlier kernel still fold, to the state they folded
to then: a run started before an upgrade resumes after it. The logs under
@test/golden/v3-logs@ are version 3 as the kernel wrote them, and each
@.state@ golden pins the state they replay to.
-}
module State.Run.ReplaySpec (spec) where

import Data.ByteString qualified as BS
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text qualified as Text
import State.Category.Graph (OpenGraph)
import State.Golden (golden)
import State.Run.Codec (decodeLogBytes)
import State.Run.Fold (replay)
import State.Run.RunGen (g, tenXGraph)
import Test.Hspec (Spec, describe, it, runIO)

spec :: Spec
spec = describe "a version 3 log" $
    mapM_ folds [("engineer-1", g), ("engineer-2", g), ("engineer-3", g), ("tenx", tenXGraph)]

folds :: (FilePath, OpenGraph) -> Spec
folds (name, flowGraph) = do
    raw <- runIO (BS.readFile ("test/golden/v3-logs/" <> name <> ".jsonl"))
    it ("folds " <> name <> ".jsonl to the state it folded to before") $
        golden ("v3-logs/" <> name <> ".state") (Text.pack (show (replayed raw)))
  where
    replayed raw = do
        envelopes <- either (Left . show) Right (decodeLogBytes raw)
        first <- maybe (Left "an empty log") Right (NonEmpty.nonEmpty envelopes)
        either (Left . show) Right (replay flowGraph first)
