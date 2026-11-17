{- | Logs this kernel wrote fold to the state they folded to then: a run
resumes from its log. The logs under @test/golden/v4-logs@ are version 4,
and each @.state@ golden pins the state they replay to, as @state show@
prints it.
-}
module State.Run.ReplaySpec (spec) where

import Data.ByteString qualified as BS
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8)
import State.Category.Graph (OpenGraph)
import State.Cli.View (showRun)
import State.Golden (golden)
import State.Run.Codec (decodeLog)
import State.Run.Fold (replay)
import State.Run.RunGen (g, loadSteps, tenXGraph)
import State.Table (Steps)
import Test.Hspec (Spec, describe, it, runIO)

spec :: Spec
spec =
    describe "a version 4 log" $ do
        steps <- runIO loadSteps
        mapM_ (folds steps) [("engineer-1", g), ("engineer-2", g), ("engineer-3", g), ("engineer-4", g), ("tenx", tenXGraph)]

folds :: Steps -> (FilePath, OpenGraph) -> Spec
folds steps (name, flowGraph) = do
    raw <- runIO (decodeUtf8 <$> BS.readFile ("test/golden/v4-logs/" <> name <> ".jsonl"))
    it ("folds " <> name <> ".jsonl to the state it folded to before") $
        golden ("v4-logs/" <> name <> ".state") (either (Text.pack . ("does not fold: " <>)) (showRun steps flowGraph) (replayed raw))
  where
    replayed raw = do
        envelopes <- either (Left . show) Right (decodeLog raw)
        first <- maybe (Left "an empty log") Right (NonEmpty.nonEmpty envelopes)
        either (Left . show) Right (replay flowGraph first)
