-- | @state resume@ over the doubles: the packet a fresh agent takes a run up from.
module State.Cli.ResumeSpec (spec) where

import Control.Monad (void, (<=<))
import Data.Entity.Event (EventRow)
import Data.Foldable (for_)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Payload.Event (Decoded (..), decodeRow, eventRow)
import Data.Payload.Upcast (shipped)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8Lenient, encodeUtf8)
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Hedgehog (Gen, annotateShow, evalIO, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import State.Cli.Shell.World (
    Act (..),
    Ran (..),
    World (..),
    addWorktree,
    appendUnread,
    askedQId,
    atWorktree,
    childRun,
    drive,
    editLog,
    hook,
    logRows,
    newWorld,
    prUrl,
    putFile,
    removeFile,
    runOf,
    sessionStart,
    startedRun,
    state,
    stateIn,
    succeeded,
    tenXAtFanOutBy,
    toImplement,
    unknownType,
 )
import State.Golden (golden)
import State.Run.RunGen (plainTask)
import Test.Hspec (Spec, before, describe, it, shouldBe, shouldContain)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "state resume over the doubles" . before newWorld $ do
    it
        "prints the packet: goal, moved worktree, newest snapshot per path, URL, notes, handover, questions, decisions, a child run, a session"
        $ \world -> do
            _ <- packedRun world
            ran <- state world ["resume"]
            pure (golden "resume/packet.txt" (decodeUtf8Lenient ran.stdout))

    it "leaves out the goal and every empty section of a fresh run" $ \world -> do
        _ <- startedRun world
        ran <- state world ["resume"]
        pure (golden "resume/fresh.txt" (decodeUtf8Lenient ran.stdout))

    it "counts neither a voided line nor its void among the header's events" $ \world -> do
        _ <- startedRun world
        fresh <- succeeded =<< state world ["resume"]
        _ <- succeeded =<< state world ["note", "--topic", "traps", "cold", "cache"]
        _ <- succeeded =<< state world ["void", "2", "wrong", "note"]
        voided <- succeeded =<< state world ["resume"]
        take 1 voided `shouldBe` take 1 fresh

    it
        "lists the gaps open or with a fix proposed, worst first and oldest first within a severity, not the closed ones"
        $ \world -> do
            _ <- startedRun world
            run <- runOf world
            first <- (+ 1) . length <$> logRows world
            let gapAt n = run <> ":" <> Text.pack (show (first + n))
                pr = "https://github.com/o/r/pull/8"
            for_
                [ ["papercut", "p", "open"]
                , ["blocker", "b", "fixed"]
                , ["blocker", "b", "proposed"]
                , ["papercut", "p", "wontfix"]
                , ["blocker", "b", "open"]
                , ["slowdown", "s", "open"]
                ]
                $ \words' ->
                    void . succeeded
                        =<< state world (["record", "gap", "--kind", "kernel", "--severity"] <> words')
            for_
                [ ["gap", "fixed", gapAt 1, "--pr", pr]
                , ["gap", "proposed", gapAt 2, "--pr", pr]
                , ["gap", "wontfix", gapAt 3, "out", "of", "scope"]
                ]
                (void . succeeded <=< state world)
            out <- succeeded =<< state world ["resume"]
            takeWhile (/= "") (dropWhile (not . ("open gaps" `Text.isPrefixOf`)) out)
                `shouldBe` [ "open gaps (4, 2 blocker):"
                           , "  " <> gapAt 2 <> " kernel blocker \"b proposed\""
                           , "  " <> gapAt 4 <> " kernel blocker \"b open\""
                           , "  " <> gapAt 5 <> " kernel slowdown \"s open\""
                           , "  " <> gapAt 0 <> " kernel papercut \"p open\""
                           ]

    it "prints the run's PR and the live state commands once it has a PR" $ \world -> do
        _ <- drive world (Record ["fuel.set", "balanced"] : toImplement)
        out <- succeeded =<< state world ["resume"]
        out `shouldContain` ["pr: " <> prUrl <> "   notes dir: /notes"]
        drop (length out - 2) out
            `shouldBe` [ ""
                       , "live state (not in the log): gh pr checks "
                            <> prUrl
                            <> "; gh pr view "
                            <> prUrl
                            <> " --json mergeable"
                       ]

    it "refuses a run with a line it cannot read, naming the line's seq and type" $ \world -> do
        run <- startedRun world
        editLog world appendUnread
        ran <- state world ["resume"]
        (ran.code, ran.out, ran.err)
            `shouldBe` ( 2
                       , []
                       ,
                           [ "state resume: run "
                                <> run
                                <> " has an event this state cannot read - seq 2, type "
                                <> unknownType
                                <> " (schema_version 1)"
                           , "fix: upgrade state"
                           ]
                       )

    describe "the run it reads" $ do
        it "reads the run named, wherever it runs" $ \world -> do
            parent <- tenXAtFanOutBy world [] [plainTask "t1" []]
            _ <- childRun world parent "/child" "t1"
            out <- succeeded =<< state world ["resume", parent]
            runOfHeader out `shouldBe` ["resume run " <> parent <> " (10x)"]

        it "reads the run the session is bound to, before the worktree's" $ \world -> do
            parent <- tenXAtFanOutBy world [] [plainTask "t1" []]
            child <- childRun world parent "/child" "t1"
            putFile
                world
                "/home/.local/state/state/bindings/s9/main"
                ("run " <> parent <> " /notes /work\n")
            worktree <- succeeded =<< state world ["resume"]
            inSession world "s9"
            bound <- succeeded =<< state world ["resume"]
            (runOfHeader worktree, runOfHeader bound)
                `shouldBe` ( ["resume run " <> child <> " (engineer)"]
                           , ["resume run " <> parent <> " (10x)"]
                           )

        it "refuses with no run named, bound or in the worktree" $ \world -> do
            ran <- state world ["resume"]
            (ran.code, ran.err)
                `shouldBe` ( 2
                           ,
                               [ "state resume: no run in this worktree - no state init ran here"
                               , "fix: state init --notes /tmp/engineer-<owner>-<repo>-<slug>/"
                               ]
                           )

    describe "--until" $ do
        it "refuses 0: a seq counts from 1" $ \world -> do
            _ <- startedRun world
            ran <- state world ["resume", "--until", "0"]
            (ran.code, take 1 ran.err)
                `shouldBe` ( 2
                           , ["state resume: --until 0 - a seq is a line's number in the log, from 1"]
                           )

        it "prints the whole packet for a seq past the last line" $ \world -> do
            _ <- packedRun world
            whole <- state world ["resume"]
            past <- state world ["resume", "--until", "1000"]
            (past.code, past.out) `shouldBe` (0, whole.out)

        it "keeps the line a void after the cut names" $ \world -> do
            run <- startedRun world
            _ <- succeeded =<< state world ["note", "--topic", "traps", "cold", "cache"]
            _ <- succeeded =<< state world ["void", "2", "wrong", "note"]
            voided <- succeeded =<< state world ["resume"]
            cut <- succeeded =<< state world ["resume", "--until", "2"]
            (noteLines voided, noteLines cut)
                `shouldBe` ([], ["notes by topic: traps 1 (last " <> run <> ":2)"])

        it
            "equals resume over a store of the log's first k lines, a line it cannot read after k refusing nothing"
            $ \_ -> hedgehog $ do
                ops <- forAll genOps
                (world, rows) <- evalIO (loggedRun ops)
                k <- forAll (Gen.int (Range.linear 1 (length rows)))
                evalIO (editLog world appendUnread)
                cut <- evalIO (state world ["resume", "--until", Text.pack (show k)])
                alone <- evalIO (withRows world (take k rows))
                annotateShow cut.err
                (cut.code, cut.stdout) === (0, alone.stdout)

        it "refuses a cut that keeps a line it cannot read, naming its seq and type" $
            \_ -> hedgehog $ do
                ops <- forAll genOps
                (world, rows) <- evalIO (loggedRun ops)
                let unread = length rows + 1
                k <- forAll (Gen.int (Range.linear unread (unread + 5)))
                evalIO (editLog world appendUnread)
                cut <- evalIO (state world ["resume", "--until", Text.pack (show k)])
                (cut.code, drop 1 (Text.splitOn " - " (Text.concat (take 1 cut.err))))
                    === ( 2
                        ,
                            [ "seq "
                                <> Text.pack (show unread)
                                <> ", type "
                                <> unknownType
                                <> " (schema_version 1)"
                            ]
                        )

    it
        "prints the same bytes for the same log, read back through the store's codec in another world"
        $ \_ -> hedgehog $ do
            ops <- forAll genOps
            (world, rows) <- evalIO (loggedRun ops)
            run <- evalIO (runOf world)
            first <- evalIO (state world ["resume", run])
            again <- evalIO $ do
                other <- elsewhere world
                editLog other (const [eventRow e | Known e <- map (decodeRow shipped) rows])
                state other ["resume", run]
            (first.code, again.stdout) === (0, first.stdout)
  where
    runOfHeader = map (Text.takeWhile (/= ',')) . take 1
    noteLines = filter ("notes by topic" `Text.isPrefixOf`)

{- | One write a generated log is made of: 'Later' notes after the clock
moved on, 'Voided' notes and voids the note at once.
-}
data Op = Note Text | Link | Ask | HandOver | Gap | Later | Voided | File
    deriving stock (Show)

genOps :: Gen [Op]
genOps =
    Gen.list
        (Range.linear 0 12)
        ( Gen.choice
            [ Note <$> Gen.element ["traps", "live"]
            , pure Link
            , pure Ask
            , pure HandOver
            , pure Gap
            , pure Later
            , pure Voided
            , pure File
            ]
        )

-- | A fresh world whose run logged these writes in one session, and its rows.
loggedRun :: [Op] -> IO (IORef World, [EventRow])
loggedRun ops = do
    world <- newWorld
    inSession world "s1"
    _ <- startedRun world
    -- Each question is asked once: its text is its place among the writes.
    for_ (zip [1 :: Int ..] ops) $ \(i, op) ->
        void . succeeded =<< case op of
            Note topic -> state world ["note", "--topic", topic, "a", "note"]
            Link ->
                state world ["artifact", "https://github.com/o/r/issues/7", "--kind", "ticket"]
            Ask -> state world ["ask", "--kind", "Design", "question", Text.pack (show i)]
            HandOver ->
                state
                    world
                    ["handover", "--reason", "context", "--summary", "s", "--next", "go on"]
            Gap -> state world ["record", "gap", "a", "gap"]
            Later -> do
                modifyIORef' world (\w -> w {clock = addUTCTime 61 w.clock})
                state world ["note", "--topic", "live", "later"]
            Voided -> do
                seq' <- (+ 1) . length <$> logRows world
                _ <- succeeded =<< state world ["note", "--topic", "traps", "wrong"]
                state world ["void", Text.pack (show seq'), "noted", "in", "error"]
            File -> do
                putFile world "/work/plan.md" (Text.pack (show i))
                state world ["artifact", "plan.md", "--kind", "plan"]
    (world,) <$> logRows world

{- | A fresh world whose store holds this world's runs: another clock,
worktree, session and files, so a packet that reads any of them differs.
-}
elsewhere :: IORef World -> IO (IORef World)
elsewhere world = do
    other <- newWorld
    stored <- (.runs) <$> readIORef world
    modifyIORef'
        other
        (\w -> w {runs = stored, clock = UTCTime (fromGregorian 2030 1 2) 7})
    atWorktree other "/elsewhere"
    inSession other "s2"
    putFile other "/work/plan.md" "another plan\n"
    pure other

-- | @state resume@ in a copy of the world whose run's store holds these rows alone.
withRows :: IORef World -> [EventRow] -> IO Ran
withRows world rows = do
    copy <- newIORef =<< readIORef world
    editLog copy (const rows)
    state copy ["resume"]

{- | A 10x run with each fact of the packet: a goal, a session, a child that
handed back, two snapshots of one path, a URL, notes under two topics, an
open question, a ruling, a question forwarded to the user, a move and a
handover. The run's id.
-}
packedRun :: IORef World -> IO Text
packedRun world = do
    inSession world "s1"
    modifyIORef' world (\w -> w {origin = Just "git@github.com:o/r.git"})
    tenX <-
        tenXAtFanOutBy
            world
            ["--goal", "Ship the resume packet"]
            [plainTask "t1" [], plainTask "t2" ["t1"]]
    _ <- hook world "resume" sessionStart
    child <- childRun world tenX "/child" "t1"
    atWorktree world "/work"
    later
    _ <-
        succeeded
            =<< stateIn
                world
                (encodeUtf8 ("READY https://github.com/o/r/pull/3\nRun: " <> child <> "\n"))
                ["handback", "engineer"]
    putFile world "/work/plan.md" "v1\n"
    _ <- succeeded =<< state world ["artifact", "plan.md", "--kind", "plan"]
    putFile world "/work/plan.md" "v2\n"
    _ <- succeeded =<< state world ["artifact", "plan.md", "--kind", "plan"]
    _ <-
        succeeded
            =<< state world ["artifact", "https://github.com/o/r/issues/7", "--kind", "ticket"]
    _ <-
        succeeded
            =<< state world ["note", "--topic", "traps", "the", "cache", "is", "cold"]
    later
    _ <- succeeded =<< state world ["note", "--topic", "live", "CI", "is", "slow"]
    _ <- succeeded =<< state world ["ask", "--kind", "Design", "which", "store?"]
    picked <- askedQId world ["--kind", "Pick", "which", "lib?"]
    _ <-
        succeeded
            =<< state
                world
                ["rule", picked, "--answer", "zod", "--why", "already used", "--cost", "none"]
    forwarded <- askedQId world ["--kind", "Scope", "ship", "t2", "too?"]
    _ <- succeeded =<< state world ["forward", forwarded]
    addWorktree world "/work2"
    _ <- succeeded =<< state world ["move", "/work2"]
    atWorktree world "/work2"
    removeFile world "/work/plan.md"
    later
    _ <-
        succeeded
            =<< state
                world
                [ "handover"
                , "--reason"
                , "context"
                , "--summary"
                , "half"
                , "--next"
                , "merge t1"
                , "--next"
                , "spawn t2"
                ]
    pure tenX
  where
    later = modifyIORef' world (\w -> w {clock = addUTCTime 90 w.clock})

-- | Every later call runs in the session @STATE_SESSION@ names.
inSession :: IORef World -> String -> IO ()
inSession world session =
    modifyIORef' world (\w -> w {env = Map.insert "STATE_SESSION" session w.env})
