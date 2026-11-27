{- | The log's contract, held by the IO interpreter over a temp run store and
by the in-memory double alike, so the two cannot drift apart; and what only
the store does: hold up under writers at once, link a child to its parent,
and keep each row in the DDL's shape.
-}
module Effects.LogSpec (spec) where

import Concurrently (bothAtOnce)
import Control.Exception (IOException)
import Control.Monad (replicateM_)
import Data.Either (fromRight, isLeft)
import Data.Entity.Event (EventRow)
import Data.Entity.Event qualified as Row
import Data.Entity.Run (RunRow (..))
import Data.Foldable (for_)
import Data.List (isPrefixOf)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Payload.Event (eventRow, runRow)
import Data.Payload.Fixtures (retiring)
import Data.Payload.Upcast (Upcasts)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Database.SQLite.Simple qualified as SQLite
import Doubles.Environment (runEnvironmentGiven)
import Doubles.Log (noRuns, runLogInMemory, written)
import Effectful (Eff, runEff, runPureEff, (:>))
import Effectful.Error.Static (runErrorNoCallStack)
import Effectful.Exception (throwIO, try)
import Effectful.State.Static.Local (evalState, get, put)
import Effects.Log (
    Log,
    Logged,
    Unread (Unread),
    children,
    exists,
    firstEvent,
    inNotes,
    locked,
    runLogIO,
    shipped,
 )
import Effects.Log qualified as Log
import Effects.Store.Connection (Durability (Full), OpenRefusal, withStore)
import Effects.Store.Events (Write (Append))
import Effects.Store.Events qualified as Store
import Hedgehog (PropertyT, annotateShow, assert, evalIO, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import State.Run.Ask (ChildTask (..), Link (..), Parent (..), Principal (..))
import State.Run.Event (
    Digest (..),
    Envelope (..),
    Event (..),
    FlowName (..),
    Note (..),
    RunId,
    Shape (..),
    Source (..),
    Start (..),
    TaskId (..),
    runIdText,
 )
import State.Run.EventGen (genEnvelope, genStart, genTime, runId)
import State.Run.Fold (Append (..), append, replay)
import State.Run.Fold qualified as Fold
import State.Run.RunGen (g)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn, shouldSatisfy)
import Test.Hspec.Hedgehog (hedgehog, modifyMaxSuccess)

spec :: Spec
spec = describe "Effects.Log" $ do
    describe "runLogIO" $ contract inStore
    describe "Doubles.Log" $ contract inMemory
    describe "the run store" $ do
        it "numbers every event of writers at once densely, losing none" $
            withSystemTempDirectory "state-store" $ \dir -> do
                let perWriter = 25 :: Int
                    -- Each append on its own connection, as each process has one.
                    writer = replicateM_ perWriter (atStore dir (locked top appendOne))
                atStore dir (locked top (const ([started top], ())))

                bothAtOnce writer writer

                atStore dir (locked top (\logged -> ([], map (.seq) . (.events) <$> logged)))
                    `shouldReturn` Right [1 .. 1 + 2 * fromIntegral perWriter]

        it "lists the runs started as a run's children" $
            withSystemTempDirectory "state-store" $ \dir -> do
                atStore dir $
                    mapM_
                        (\e -> locked e.run (const ([e], ())))
                        [started top, childOf top child, started other]

                atStore dir (traverse children [top, child, other])
                    `shouldReturn` [[child], [], []]

        it "lists two children started in one millisecond in the order they started" $
            withSystemTempDirectory "state-store" $ \dir -> do
                let first = childOf top child
                    second = (childOf top other) {ts = addUTCTime 0.0001 first.ts}
                atStore dir $
                    mapM_ (\e -> locked e.run (const ([e], ()))) [started top, first, second]

                atStore dir (children top) `shouldReturn` [child, other]

        modifyMaxSuccess (const 30) $ do
            it
                "writes each event's row in the DDL's shape: 24-character time, schema_version 1, 16-hex hook_digest"
                . hedgehog
                $ do
                    events <- forAll (Gen.list (Range.linear 1 8) genEnvelope)
                    let logged = started top : zipWith (\n e -> e {run = top, seq = n}) [2 ..] events
                    stored <- evalIO . withSystemTempDirectory "state-store" $ \dir -> do
                        atStore dir (locked top (const (logged, ())))
                        storeRows
                            dir
                            "SELECT time, schema_version, hook_digest FROM events WHERE run_id = ? ORDER BY seq"
                            (SQLite.Only (runIdText top))
                    annotateShow stored
                    for_ (zip logged stored) $ \(e, (time, version, digest)) -> do
                        Text.length time === 24
                        version === (1 :: Int)
                        case e.source of
                            Cli -> digest === Nothing
                            Hook (Digest hook) -> digest === Just hook
                        assert
                            ( all
                                (\d -> Text.length d == 16 && Text.all (`elem` ['0' .. '9'] <> ['a' .. 'f']) d)
                                digest
                            )

            it
                "writes a run's runs row in its first event's transaction, a function of that event alone"
                . hedgehog
                $ do
                    start <- forAll genStart
                    ts <- forAll genTime
                    let begun = (started top) {ts, event = Started start}
                        parents = [p.run | ByRole p _ _ <- [start.principal]]
                    -- A run is never its own parent: the shell starts a child under another run.
                    assert (top `notElem` parents)
                    indexed <- evalIO . withSystemTempDirectory "state-store" $ \dir -> do
                        atStore dir (mapM_ (\p -> locked p (const ([started p], ()))) parents)
                        atStore dir (locked top (const ([begun], ())))
                        storeRows
                            dir
                            "SELECT id, parent_run_id, flow, notes_dir, created_at FROM runs WHERE id = ?"
                            (SQLite.Only (runIdText top))
                    indexed
                        === [ (row.id, row.parentRunId, row.flow, row.notesDir, row.createdAt)
                            | Just row <- [runRow begun]
                            ]

{- | Runs a program, read through these upcasts, on a log with these runs,
each its events, then these writes of raw rows as another writer left them,
past the domain's mapping; the program gets nothing else.
-}
type Backend =
    forall a.
    Upcasts ->
    [Envelope] ->
    [Write] ->
    (forall es. (Log :> es) => Eff es a) ->
    IO a

-- | A temp run store, found as the shell finds it: from @XDG_STATE_HOME@.
inStore :: Backend
inStore upcasts seeded byHand program = withSystemTempDirectory "state-log" $ \dir -> do
    atStore dir (mapM_ (\e -> locked e.run (const ([e], ()))) seeded)
    -- Raw rows through the store's own write, past the domain's mapping.
    withStore
        Full
        (dir </> "state" </> "kernel-v2.db")
        (for_ byHand . writeRaw)
        >>= either (fail . show) pure
    atStoreWith upcasts dir program
  where
    writeRaw store write = Store.locked store (runOf write) (const (Just write, ()))

-- | A program on the run store under this @XDG_STATE_HOME@, which it must open.
atStore :: FilePath -> (forall es. (Log :> es) => Eff es a) -> IO a
atStore = atStoreWith shipped

atStoreWith ::
    Upcasts -> FilePath -> (forall es. (Log :> es) => Eff es a) -> IO a
atStoreWith upcasts dir program =
    runEff
        ( runErrorNoCallStack @OpenRefusal
            . runEnvironmentGiven (Map.fromList [("XDG_STATE_HOME", dir)])
            . runLogIO upcasts Full
            $ program
        )
        >>= either (fail . show) pure

-- | The rows a query reads from the store under this @XDG_STATE_HOME@.
storeRows ::
    (SQLite.ToRow q, SQLite.FromRow r) => FilePath -> SQLite.Query -> q -> IO [r]
storeRows dir sql params =
    SQLite.withConnection
        (dir </> "state" </> "kernel-v2.db")
        (\c -> SQLite.query c sql params)

inMemory :: Backend
inMemory upcasts seeded byHand program =
    pure . runPureEff . evalState noRuns . runLogInMemory upcasts $ do
        mapM_ (\e -> locked e.run (const ([e], ()))) seeded
        for_ byHand $ \write ->
            get >>= either (throwIO . userError) put . written (runId (runOf write)) write
        program

-- | The run a write's rows belong to.
runOf :: Write -> Text.Text
runOf = \case
    Append (row :| _) -> row.runId
    Store.Start _ (row :| _) -> row.runId

contract :: Backend -> Spec
contract on = do
    let backend :: [Envelope] -> (forall es. (Log :> es) => Eff es a) -> IO a
        backend seeded = on shipped seeded []
    it "starts a run, appends each decision's events and reads them back" $ do
        seen <- backend [] $ do
            before <- exists top
            first <- locked top (([started top],) . eventsOf)
            second <- locked top (([followed top 2],) . eventsOf)
            after <- locked top (([],) . eventsOf)
            line <- firstEvent top
            pure (before, first, second, after, line)

        seen
            `shouldBe` ( False
                       , Right []
                       , Right [started top]
                       , Right [started top, followed top 2]
                       , Just (Right (started top))
                       )

    it "keeps no run that a decision appends nothing to" $ do
        kept <- backend [] (locked top (const ([], ())) >> exists top)

        kept `shouldBe` False

    it "reads the first event of a run, and none of an absent one" $ do
        firsts <- backend [started top] (traverse firstEvent [top, other])

        firsts `shouldBe` [Just (Right (started top)), Nothing]

    it "keeps each run's events apart" $ do
        seen <-
            backend
                [started top, started other]
                (locked other (\logged -> ([], map (.run) <$> eventsOf logged)))

        seen `shouldBe` Right [other]

    it "throws on an event whose seq the log holds already" $ do
        failed <-
            backend
                [started top]
                (try @IOException (locked top (const ([followed top 1], ()))))

        failed `shouldSatisfy` isLeft

    it "throws on an event that leaves a gap in the seqs" $ do
        failed <-
            backend
                [started top]
                (try @IOException (locked top (const ([followed top 3], ()))))

        failed `shouldSatisfy` isLeft

    it "lists the runs started in a notes dir, oldest first" $ do
        found <-
            backend
                [started top, childOf top child, started other]
                (traverse inNotes ["/notes", "/child", "/none"])

        found `shouldBe` [[top, other], [child], []]

    it "throws on events for a run never started that do not start it" $ do
        failed <-
            backend [] (try @IOException (locked top (const ([followed top 1], ()))))

        failed `shouldSatisfy` isLeft

    it "throws on a second row of a hook digest the run holds already" $ do
        failed <- backend [started top] $ do
            locked top (const ([hooked {seq = 2}], ()))
            try @IOException (locked top (const ([hooked {seq = 3}], ())))

        failed `shouldSatisfy` isLeft

    it "lists a run's children by its runs row, its first row one it cannot read" $ do
        found <-
            on
                shipped
                [started top]
                [ Store.Start index (unknownStart :| [])
                | Just index <- [runRow (childOf top child)]
                ]
                (children top)

        found `shouldBe` [child]

    modifyMaxSuccess (const 30) $ do
        it
            "only grows: each decision's log holds the one before it, its seqs dense from 1"
            . hedgehog
            $ do
                batches <- forAll (Gen.list (Range.linear 1 5) (Gen.int (Range.linear 1 3)))
                reads' <- evalIO $ backend [started top] $ do
                    let decide size = \case
                            Right logged ->
                                ( [ followed top (fromIntegral logged.rows + k) | k <- [1 .. fromIntegral size]
                                  ]
                                , logged.events
                                )
                            Left _ -> ([], [])
                    before <- traverse (locked top . decide) batches
                    final <- locked top (\logged -> ([], fromRight [] (eventsOf logged)))
                    pure (before <> [final])
                annotateShow reads'
                assertGrows reads'
                map (.seq) (last reads') === [1 .. fromIntegral (1 + sum batches)]

        it "appends a hook's event fired again once" . hedgehog $ do
            fired <- forAll (Gen.int (Range.linear 1 4))
            logged <- evalIO $ backend [started top] $ do
                replicateM_ fired (locked top hookOnce)
                locked top (\logged -> ([], fromRight [] (eventsOf logged)))
            map (.source) logged === [Cli, hooked.source]

    it "gives a decision the row it cannot read, naming its seq and type" $ do
        refused <-
            on shipped [started top] [appended unknownRow] $
                locked top $ \case
                    Left unread -> ([], Left unread)
                    Right logged -> ([followed top (fromIntegral logged.rows + 1)], Right ())

        refused
            `shouldBe` Left (Unread 2 "no_such_event" 1)

    it "appends after a retired row at the next seq, the row skipped" $ do
        logged <- on retiring [started top] [appended (retiredRow Nothing)] $ do
            locked top appendOne
            locked top (\logged -> ([], (.seq) <$> fromRight [] (eventsOf logged)))

        logged `shouldBe` [1, 3]

    it "skips a hook fired again on a retired row of that hook" $ do
        logged <- on retiring [started top] [appended (retiredRow (Just "0123456789abcdef"))] $ do
            locked top hookOnce
            locked top (\logged -> ([], (\l -> (map (.seq) l.events, l.rows)) <$> logged))

        logged `shouldBe` Right ([1], 2)

-- | The log's events, or the row it cannot read.
eventsOf :: Either Unread Logged -> Either Unread [Envelope]
eventsOf = fmap (.events)

-- | A write of this one row, appended.
appended :: EventRow -> Write
appended row = Append (row :| [])

-- | Seq 2 of 'top', of a type no kernel knows.
unknownRow :: EventRow
unknownRow = (eventRow (followed top 2)) {Row.eventType = "no_such_event"}

-- | The first row of 'child' under 'top', of a type no kernel knows.
unknownStart :: EventRow
unknownStart = (eventRow (childOf top child)) {Row.eventType = "no_such_event"}

-- | Seq 2 of 'top', of the type 'retiring' retired, written by this hook if any.
retiredRow :: Maybe Text.Text -> EventRow
retiredRow digest =
    (eventRow (followed top 2))
        { Row.eventType = "legacy.note"
        , Row.hookDigest = digest
        }

-- | Each read holds the one before it as its prefix.
assertGrows :: [[Envelope]] -> PropertyT IO ()
assertGrows reads' =
    for_ (zip reads' (drop 1 reads')) $ \(before, after) -> assert (before `isPrefixOf` after)

{- | A hook's event appended as the shell appends one: unless the replayed
log has its id already ('append'), whose unique key the store holds too.
-}
hookOnce :: Either a Logged -> ([Envelope], ())
hookOnce = \case
    Right logged
        | first : rest <- logged.events
        , Right state <- replay g (first :| rest)
        , let next = hooked {seq = logged.rows + 1}
        , Right (Appended _) <-
            append g state {Fold.seen = state.seen <> logged.seen} next ->
            ([next], ())
    _ -> ([], ())

-- | A hook's event on 'top', its seq set at append.
hooked :: Envelope
hooked = (followed top 0) {source = Hook (Digest "0123456789abcdef")}

-- | A run's first event.
started :: RunId -> Envelope
started run =
    envelope
        run
        1
        ( Started
            Start
                { flow = EngineerFlow
                , notes = "/notes"
                , principal = ByUser OwnPr
                , interface = Set.empty
                }
        )

-- | A child's first event, under this parent.
childOf :: RunId -> RunId -> Envelope
childOf parent run =
    envelope
        run
        1
        ( Started
            Start
                { flow = EngineerFlow
                , notes = "/child"
                , principal = ByRole (Parent parent (InFan (Tasked (TaskId "t1")))) OwnPr minBound
                , interface = Set.empty
                }
        )

-- | An event past the start, at this seq.
followed :: RunId -> Integer -> Envelope
followed run n = envelope run (fromIntegral n) (Refused (Note "n" "f"))

-- | One more event after those logged.
appendOne :: Either a Logged -> ([Envelope], ())
appendOne = \case
    Right logged -> ([followed top (fromIntegral logged.rows + 1)], ())
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
