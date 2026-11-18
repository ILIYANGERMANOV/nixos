{- | The log's contract, held by the IO interpreter over a temp run store and
by the in-memory double alike, so the two cannot drift apart; and what only
the store does: hold up under writers at once, and link a child to its parent.
-}
module Effects.LogSpec (spec) where

import Concurrently (bothAtOnce)
import Control.Exception (IOException)
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Doubles.Environment (runEnvironmentGiven)
import Doubles.Log (Runs (..), runLogInMemory)
import Effectful (Eff, runEff, runPureEff, (:>))
import Effectful.Exception (try)
import Effectful.State.Static.Local (evalState)
import Effects.Log (Log, exists, firstLine, inNotes, locked, runLogIO)
import Effects.Store (Durability (Full), children, withStore)
import Effects.Store qualified as Store
import State.Run.Ask (ChildTask (..), Link (..), Parent (..), Principal (..))
import State.Run.Codec (encodeLine)
import State.Run.Event (Envelope (..), Event (..), FlowName (..), Note (..), RunId, Shape (..), Source (..), Start (..), TaskId (..))
import State.Run.EventGen (runId)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn, shouldSatisfy)

spec :: Spec
spec = describe "Effects.Log" $ do
    describe "runLogIO" $ contract inStore
    describe "Doubles.Log" $ contract inMemory
    describe "the run store" $ do
        it "numbers every event of writers at once densely, losing none" $
            withSystemTempDirectory "state-store" $ \dir -> do
                let db = dir </> "kernel.db"
                    perWriter = 25 :: Int
                    -- Each append on its own connection, as each process has one.
                    writer = mapM_ (\_ -> withStore Full db (\store -> Store.locked store top appendOne)) [1 .. perWriter]
                withStore Full db (\store -> Store.locked store top (const ([started top], ())))

                bothAtOnce writer writer

                withStore Full db (\store -> Store.locked store top (\logged -> ([], map (.seq) <$> logged)))
                    `shouldReturn` Right [1 .. 1 + 2 * fromIntegral perWriter]

        it "lists the runs started as a run's children" $
            withSystemTempDirectory "state-store" $ \dir -> withStore Full (dir </> "kernel.db") $ \store -> do
                mapM_ (\e -> Store.locked store e.run (const ([e], ()))) [started top, childOf top child, started other]

                traverse (children store) [top, child, other] `shouldReturn` [[child], [], []]

        it "lists two children started in one second in the order they started, though their times' text sorts the other way" $
            withSystemTempDirectory "state-store" $ \dir -> withStore Full (dir </> "kernel.db") $ \store -> do
                -- Written as 00:00:00Z and 00:00:00.1Z: '.' sorts before 'Z'.
                let first = childOf top child
                    second = (childOf top other) {ts = addUTCTime 0.1 first.ts}
                mapM_ (\e -> Store.locked store e.run (const ([e], ()))) [started top, first, second]

                children store top `shouldReturn` [child, other]

{- | Runs a program on a log with these runs, each its rows; the program
gets nothing else.
-}
type Backend = forall a. [Envelope] -> (forall es. (Log :> es) => Eff es a) -> IO a

-- | A temp run store, found as the shell finds it: from @XDG_STATE_HOME@.
inStore :: Backend
inStore seeded program = withSystemTempDirectory "state-log" $ \dir -> do
    let env = Map.fromList [("XDG_STATE_HOME", dir)]
    runEff . runEnvironmentGiven env . runLogIO Full $ do
        mapM_ (\e -> locked e.run (const ([e], ()))) seeded
        program

inMemory :: Backend
inMemory seeded program =
    pure . runPureEff . evalState (Runs []) . runLogInMemory $ do
        mapM_ (\e -> locked e.run (const ([e], ()))) seeded
        program

contract :: Backend -> Spec
contract backend = do
    it "starts a run, appends each decision's events and reads them back" $ do
        seen <- backend [] $ do
            before <- exists top
            first <- locked top ([started top],)
            second <- locked top ([followed top 2],)
            after <- locked top ([],)
            line <- firstLine top
            pure (before, first, second, after, line)

        seen `shouldBe` (False, Right [], Right [started top], Right [started top, followed top 2], Just (encodeLine (started top)))

    it "keeps no run that a decision appends nothing to" $ do
        kept <- backend [] (locked top ([],) >> exists top)

        kept `shouldBe` False

    it "reads the first event of a run, and none of an absent one" $ do
        firsts <- backend [started top] (traverse firstLine [top, other])

        firsts `shouldBe` [Just (encodeLine (started top)), Nothing]

    it "keeps each run's events apart" $ do
        seen <- backend [started top, started other] (locked other (\logged -> ([], map (.run) <$> logged)))

        seen `shouldBe` Right [other]

    it "throws on an event whose seq the log holds already" $ do
        failed <- backend [started top] (try @IOException (locked top ([followed top 1],)))

        failed `shouldSatisfy` isLeft

    it "throws on an event that leaves a gap in the seqs" $ do
        failed <- backend [started top] (try @IOException (locked top ([followed top 3],)))

        failed `shouldSatisfy` isLeft

    it "lists the runs started in a notes dir, oldest first" $ do
        found <- backend [started top, childOf top child, started other] (traverse inNotes ["/notes", "/child", "/none"])

        found `shouldBe` [[top, other], [child], []]

    it "throws on events for a run never started that do not start it" $ do
        failed <- backend [] (try @IOException (locked top ([followed top 1],)))

        failed `shouldSatisfy` isLeft

-- | A run's first event.
started :: RunId -> Envelope
started run = envelope run 1 (Started Start {flow = EngineerFlow, notes = "/notes", principal = ByUser OwnPr, interface = Set.empty})

-- | A child's first event, under this parent.
childOf :: RunId -> RunId -> Envelope
childOf parent run = envelope run 1 (Started Start {flow = EngineerFlow, notes = "/child", principal = ByRole (Parent parent (InFan (Tasked (TaskId "t1")))) OwnPr minBound, interface = Set.empty})

-- | An event past the start, at this seq.
followed :: RunId -> Integer -> Envelope
followed run n = envelope run (fromIntegral n) (Refused (Note "n" "f"))

-- | One more event after those logged.
appendOne :: Either a [Envelope] -> ([Envelope], ())
appendOne = \case
    Right logged -> ([followed top (fromIntegral (length logged) + 1)], ())
    Left _ -> ([], ())

envelope :: RunId -> Integer -> Event -> Envelope
envelope run n event =
    Envelope
        { source = Cli
        , seq = fromIntegral n
        , ts = UTCTime (fromGregorian 2026 11 13) 0
        , run
        , head = Nothing
        , session = Nothing
        , event
        }

top, child, other :: RunId
top = runId "00010203"
child = runId "0a0b0c0d"
other = runId "ffff0000"
