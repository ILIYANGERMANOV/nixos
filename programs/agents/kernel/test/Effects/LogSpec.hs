module Effects.LogSpec (spec) where

import Data.ByteString qualified as BS
import Data.Maybe (fromJust)
import Data.Set qualified as Set
import Data.Text.IO qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (runEff)
import Effects.Log (exists, firstLine, locked, runLogIO)
import State.Ask (Principal (..))
import State.Codec (LogError (..), encodeLine)
import State.Event (Envelope (..), Event (..), FlowName (..), Source (..), Start (..), parseRunId)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, around, describe, it, shouldBe, shouldReturn)

spec :: Spec
spec = describe "Effects.Log" $ around (withSystemTempDirectory "state-log") $ do
    it "creates an absent log, appends a decision's lines and reads them back" $ \dir -> do
        let path = dir </> "events.jsonl"

        before <- runEff . runLogIO $ exists path
        seen <- runEff . runLogIO $ locked path ([started],)
        after <- runEff . runLogIO $ locked path ([],)

        before `shouldBe` False
        (seen, after) `shouldBe` (Right [], Right [started])
        Text.readFile path `shouldReturn` (encodeLine started <> "\n")

    it "reads the first line of a log, and none of an absent one" $ \dir -> do
        let path = dir </> "events.jsonl"
        Text.writeFile path "first\nsecond\n"

        firsts <- runEff . runLogIO $ traverse firstLine [path, dir </> "absent"]

        firsts `shouldBe` [Just "first", Nothing]

    it "reads a log that is not UTF-8 as a malformed first line" $ \dir -> do
        let path = dir </> "events.jsonl"
        BS.writeFile path "\xff\n"

        seen <- runEff . runLogIO $ locked path (\read' -> ([], either (Just . (.line)) (const Nothing) read'))

        seen `shouldBe` Just 0

-- | A run's first line.
started :: Envelope
started =
    Envelope
        { source = Cli
        , seq = 1
        , ts = UTCTime (fromGregorian 2026 11 13) 0
        , run = fromJust (parseRunId "00010203")
        , head = Nothing
        , session = Nothing
        , event = Started Start {flow = EngineerFlow, notes = "/notes", principal = ByUser, interface = Set.empty, task = ""}
        }
