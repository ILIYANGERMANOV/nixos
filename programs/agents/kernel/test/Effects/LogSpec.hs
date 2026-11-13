{- | The log's contract, held by the IO interpreter over a temp dir and by the
in-memory double over its disk alike, so the two cannot drift apart.
-}
module Effects.LogSpec (spec) where

import Control.Exception (IOException)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Set qualified as Set
import Data.Time (UTCTime (..), fromGregorian)
import Doubles.FileSystem (Disk (..))
import Doubles.Log (runLogInMemory)
import Effectful (Eff, runEff, runPureEff, (:>))
import Effectful.Exception (try)
import Effectful.State.Static.Local (evalState)
import Effects.Log (Log, exists, firstLine, locked, runLogIO)
import State.Ask (Principal (..))
import State.Codec (LogError (..), encodeLine)
import State.Event (Envelope (..), Event (..), FlowName (..), Source (..), Start (..), parseRunId)
import System.FilePath ((</>))
import System.IO.Error (isDoesNotExistError)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec = describe "Effects.Log" $ do
    describe "runLogIO" $ contract onDisk
    describe "Doubles.Log" $ contract inMemory

{- | Runs a program on a directory that exists and holds these files, by name;
the program gets the directory.
-}
type Backend = forall a. [(FilePath, ByteString)] -> (forall es. (Log :> es) => FilePath -> Eff es a) -> IO a

onDisk :: Backend
onDisk seeded program = withSystemTempDirectory "state-log" $ \dir -> do
    mapM_ (\(name, bytes) -> BS.writeFile (dir </> name) bytes) seeded
    runEff . runLogIO $ program dir

inMemory :: Backend
inMemory seeded program =
    pure . runPureEff . evalState disk . runLogInMemory $ program dir
  where
    dir = "/logs"
    disk = Disk {files = Map.fromList [(dir </> name, bytes) | (name, bytes) <- seeded], dirs = Set.fromList ["/", dir], cwd = "/"}

contract :: Backend -> Spec
contract backend = do
    it "creates an absent log, appends each decision's lines and reads them back" $ do
        seen <- backend [] $ \dir -> do
            let path = dir </> "events.jsonl"
            before <- exists path
            first <- locked path ([started],)
            second <- locked path ([started],)
            after <- locked path ([],)
            line <- firstLine path
            pure (before, first, second, after, line)

        seen `shouldBe` (False, Right [], Right [started], Right [started, started], Just (encodeLine started))

    it "creates the log even when a decision appends nothing" $ do
        created <- backend [] $ \dir -> do
            let path = dir </> "events.jsonl"
            locked path ([],) >> exists path

        created `shouldBe` True

    it "reads the first line of a log, and none of an absent one" $ do
        firsts <- backend [("events.jsonl", "first\nsecond\n")] $ \dir ->
            traverse firstLine [dir </> "events.jsonl", dir </> "absent"]

        firsts `shouldBe` [Just "first", Nothing]

    it "reads a log that is not UTF-8 as a malformed line 0, and its first line leniently" $ do
        seen <- backend [("events.jsonl", "\xff\n")] $ \dir -> do
            let path = dir </> "events.jsonl"
            bad <- locked path (\read' -> ([], either (Just . (.line)) (const Nothing) read'))
            line <- firstLine path
            pure (bad, line)

        seen `shouldBe` (Just 0, Just "\xfffd")

    it "throws on a log whose directory does not exist" $ do
        failed <- backend [] $ \dir -> try @IOException (locked (dir </> "absent" </> "events.jsonl") ([started],))

        either isDoesNotExistError (const False) failed `shouldBe` True

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
        , event = Started Start {flow = EngineerFlow, notes = "/notes", principal = ByUser, interface = Set.empty, task = Nothing}
        }
