-- | @state@'s context facts over the doubles: init's goal and repo, artifacts, show, notes and handovers.
module State.Cli.Shell.ContextSpec (spec) where

import Data.Foldable (for_)
import Data.IORef (IORef, modifyIORef')
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)
import Hedgehog (evalIO, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Numeric.Natural (Natural)
import State.Artifact (
    Artifact (..),
    FileArtifact (..),
    FileRef (..),
    absPathText,
    fileKindText,
    keepsContent,
    sha256Of,
    sha256Text,
 )
import State.Cli.Shell.World (
    Ran (..),
    World (..),
    atWorktree,
    delegating,
    draftPr,
    logged,
    loggedEvents,
    newWorld,
    putBytes,
    putFile,
    removeFile,
    startedIn,
    startedRun,
    state,
    stateIn,
    succeeded,
    untaskedChild,
 )
import State.Protocol.Advice (Readiness (..))
import State.Run.Event (Envelope (..), Event (..), Repo (..), Start (..))
import Test.Hspec (Spec, before, describe, it, shouldBe, shouldReturn)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "state's context facts over the doubles" . before newWorld $ do
    describe "init" $ do
        it "logs the goal word for word, the git top as worktree and origin's repo" $ \world -> do
            modifyIORef' world (\w -> w {origin = Just "git@github.com:o/r.git"})
            _ <- startedIn world ["--goal", "ship  the fix"]
            starts <- startsOf world
            starts
                `shouldBe` [(Just "ship  the fix", "/work", Just (Repo "o" "r"))]

        it "leaves goal and repo out with no --goal and no GitHub origin" $ \world -> do
            modifyIORef' world (\w -> w {origin = Just "https://gitlab.com/o/r"})
            _ <- startedRun world
            startsOf world `shouldReturn` [(Nothing, "/work", Nothing)]

    describe "artifact" $ do
        it
            "registers a file by its absolute path, digest and size, and shows its stored bytes"
            $ \world -> do
                run <- startedRun world
                putFile world "/work/notes.md" "hi\n"
                registered <- state world ["artifact", "notes.md", "--kind", "research"]
                removeFile world "/work/notes.md"
                shown <- state world ["artifact", "show", run <> ":2"]
                (registered.code, registered.out, shown.code, shown.out)
                    `shouldBe` ( 0
                               ,
                                   [ "artifact "
                                        <> run
                                        <> ":2 research sha256:"
                                        <> digest "hi\n"
                                        <> " 3 bytes, content stored"
                                   , "show: state artifact show " <> run <> ":2"
                                   ]
                               , 0
                               , ["hi"]
                               )

        it "refuses a missing path as file_unreadable and logs nothing" $ \world -> do
            _ <- startedRun world
            ran <- state world ["artifact", "gone.md", "--kind", "notes"]
            (ran.code, take 1 ran.err)
                `shouldBe` ( 2
                           ,
                               [ "state artifact: file_unreadable /work/gone.md - it does not exist, or may not be read"
                               ]
                           )
            loggedEvents world `shouldReturn` ["started"]

        it "registers a URL as given and shows it" $ \world -> do
            run <- startedRun world
            registered <-
                state world ["artifact", "https://github.com/o/r/issues/7", "--kind", "ticket"]
            shown <- state world ["artifact", "show", run <> ":2"]
            (registered.out, shown.out)
                `shouldBe` (
                               [ "artifact " <> run <> ":2 ticket https://github.com/o/r/issues/7"
                               , "show: state artifact show " <> run <> ":2"
                               ]
                           , ["https://github.com/o/r/issues/7"]
                           )
            loggedEvents world `shouldReturn` ["started", "artifact"]

        it "refuses text that is no URI for a URL's kind and logs nothing" $ \world -> do
            _ <- startedRun world
            refused <- state world ["artifact", "not a uri", "--kind", "ticket"]
            refused.code `shouldBe` 2
            loggedEvents world `shouldReturn` ["started"]

        it "logs a file over the cap by path only, and show exits 3 naming its digest" $ \world -> do
            run <- startedRun world
            let big = Text.replicate 1048577 "a"
            putFile world "/work/big.log" big
            registered <- state world ["artifact", "big.log", "--kind", "download"]
            shown <- state world ["artifact", "show", run <> ":2"]
            (registered.out, shown.code, take 1 shown.err)
                `shouldBe` (
                               [ "artifact "
                                    <> run
                                    <> ":2 download sha256:"
                                    <> digest big
                                    <> " 1048577 bytes, path only"
                               , "show: state artifact show " <> run <> ":2"
                               ]
                           , 3
                           ,
                               [ "state artifact: /work/big.log - sha256:"
                                    <> digest big
                                    <> ", its bytes not stored: a transcript, or over the cap"
                               ]
                           )

        -- Far under the cap, as a file near it would slow every try.
        it "shows the bytes of any file under the cap as registered" $ \_ -> hedgehog $ do
            world <- evalIO newWorld
            kind <- forAll (Gen.filter keepsContent Gen.enumBounded)
            bytes <- forAll (Gen.bytes (Range.linear 0 512))
            shown <- evalIO $ do
                run <- startedRun world
                putBytes world "/work/a.bin" bytes
                _ <-
                    succeeded =<< state world ["artifact", "a.bin", "--kind", fileKindText kind]
                state world ["artifact", "show", run <> ":2"]
            (shown.code, shown.stdout) === (0, bytes)

        it "exits 4 for a line that is no artifact, and for a line the run lacks" $ \world -> do
            run <- startedRun world
            started <- state world ["artifact", "show", run <> ":1"]
            missing <- state world ["artifact", "show", run <> ":9"]
            (started.code, take 1 started.err, missing.code)
                `shouldBe` (4, ["state artifact: artifact " <> run <> ":1 - it is a started line"], 4)

        it "refuses a --from that names no artifact, before any write" $ \world -> do
            _ <- startedRun world
            putFile world "/work/a.md" "a"
            ran <- state world ["artifact", "a.md", "--kind", "plan", "--from", "1"]
            ran.code `shouldBe` 2
            loggedEvents world `shouldReturn` ["started"]

    describe "path outcomes" $ do
        it "registers a plan.done's path as a plan artifact in the outcome's append" $ \world -> do
            _ <- startedRun world
            putFile world "/work/plan.md" "the plan"
            atPlan world
            ran <- state world ["record", "plan.done", "plan.md"]
            (ran.code, last ran.out) `shouldBe` (0, "next: state next")
            artifacts <- artifactsLogged world
            artifacts `shouldBe` ["/work/plan.md"]

        it
            "logs a plan.done whose plan is missing, with no artifact, and names the path"
            $ \world -> do
                _ <- startedRun world
                atPlan world
                ran <- state world ["record", "plan.done", "gone.md"]
                events <- loggedEvents world
                artifacts <- artifactsLogged world
                (ran.code, take 1 ran.out, last events, artifacts)
                    `shouldBe` ( 0
                               , ["file_unreadable /work/gone.md: gone or unreadable, no artifact logged"]
                               , "plan.done"
                               , []
                               )

        it "refuses a breakdown whose --tasks file is missing, and logs nothing" $ \world -> do
            _ <- startedIn world ["--flow", "10x"]
            _ <-
                succeeded
                    =<< state world ["override", "breakdown", "the", "plan", "is", "agreed"]
            before' <- loggedEvents world
            ran <- state world ["record", "breakdown.done", "--tasks", "/work/gone.json"]
            (ran.code, take 1 ran.err)
                `shouldBe` ( 2
                           ,
                               [ "state record: file_unreadable /work/gone.json - it does not exist, or may not be read"
                               ]
                           )
            loggedEvents world `shouldReturn` before'

    describe "note" $
        it "logs the note and prints its row and the next command" $ \world -> do
            run <- startedRun world
            ran <- state world ["note", "--topic", "traps", "the", "cache", "lies"]
            ran.out `shouldBe` ["note " <> run <> ":2 traps", "next: state next"]
            loggedEvents world `shouldReturn` ["started", "note"]

    describe "handover" $ do
        it "logs no artifact when no registered file changed" $ \world -> do
            run <- startedRun world
            putFile world "/work/notes.md" "n"
            _ <- state world ["artifact", "notes.md", "--kind", "notes"]
            ran <- handover world
            ran.out
                `shouldBe` ["handover " <> run <> ":3", "resume with: state resume " <> run]
            loggedEvents world `shouldReturn` ["started", "artifact", "handover"]

        it
            "registers a changed file again, derived from the last, and skips a deleted one by name (R7)"
            $ \world -> do
                run <- startedRun world
                putFile world "/work/notes.md" "v1"
                putFile world "/work/b.md" "b"
                _ <- state world ["artifact", "notes.md", "--kind", "notes"]
                _ <- state world ["artifact", "b.md", "--kind", "notes"]
                putFile world "/work/notes.md" "v2"
                removeFile world "/work/b.md"
                ran <- handover world
                removeFile world "/work/notes.md"
                edited <- state world ["artifact", "show", run <> ":4"]
                original <- state world ["artifact", "show", run <> ":3"]
                derived <- artifactParents world
                (ran.code, ran.out, edited.out, original.out, derived)
                    `shouldBe` ( 0
                               ,
                                   [ "skipped /work/b.md: gone or unreadable, its last snapshot kept"
                                   , "artifact "
                                        <> run
                                        <> ":4 notes sha256:"
                                        <> digest "v2"
                                        <> " 2 bytes, content stored"
                                   , "handover " <> run <> ":5"
                                   , "resume with: state resume " <> run
                                   ]
                               , ["v2"]
                               , ["b"]
                               , [Nothing, Nothing, Just 2]
                               )

    describe "the run's end (R8)" $ do
        it "registers a changed file again before stop" $ \world -> do
            _ <- startedRun world
            putFile world "/work/notes.md" "v1"
            _ <- state world ["artifact", "notes.md", "--kind", "notes"]
            putFile world "/work/notes.md" "v2"
            ran <- state world ["stop", "blocked", "no", "access"]
            ran.code `shouldBe` 0
            loggedEvents world `shouldReturn` ["started", "artifact", "artifact", "stop"]

        -- next reads only the fold: the flow it ends is not re-snapshotted (a known gap).
        it
            "reads no file in next: a registered file changed and one deleted log no artifact as the ready PR ends the run"
            $ \world -> do
                _ <- startedRun world
                putFile world "/work/notes.md" "v1"
                putFile world "/work/b.md" "b"
                _ <- succeeded =<< state world ["artifact", "notes.md", "--kind", "notes"]
                _ <- succeeded =<< state world ["artifact", "b.md", "--kind", "notes"]
                _ <- succeeded =<< state world ["override", "ready", "the", "PR", "is", "up"]
                putFile world "/work/notes.md" "v2"
                removeFile world "/work/b.md"
                modifyIORef' world (\w -> w {pr = draftPr IsReady})
                ran <- succeeded =<< state world ["next"]
                events <- loggedEvents world
                (any ("skipped " `Text.isPrefixOf`) ran, drop 4 events)
                    `shouldBe` (False, ["ready.done"])

        it "registers a changed file again before the hand-back that ends the run" $ \world -> do
            chief <- delegating world
            child <- untaskedChild world chief
            atWorktree world "/work"
            putFile world "/work/notes.md" "v1"
            _ <- succeeded =<< state world ["artifact", "notes.md", "--kind", "notes"]
            _ <- succeeded =<< state world ["record", "next.done"]
            putFile world "/work/notes.md" "v2"
            _ <-
                succeeded
                    =<< stateIn
                        world
                        ("READY https://github.com/o/r/pull/1\nRun: " <> encodeUtf8 child)
                        ["handback", "engineer", "--child", child]
            artifacts <- artifactsLogged world
            artifacts `shouldBe` ["/work/notes.md", "/work/notes.md"]

-- | The run started, recorded to its plan step.
atPlan :: IORef World -> IO ()
atPlan world =
    for_ [["fuel.set", "balanced"], ["gather.enough"], ["gather/notes.done"]] $ \argv ->
        succeeded =<< state world ("record" : argv)

handover :: IORef World -> IO Ran
handover world =
    state
        world
        [ "handover"
        , "--reason"
        , "context"
        , "--summary"
        , "half done"
        , "--next"
        , "finish"
        ]

digest :: Text -> Text
digest = sha256Text . sha256Of . encodeUtf8

-- | Each start's goal, worktree and repo.
startsOf :: IORef World -> IO [(Maybe Text, FilePath, Maybe Repo)]
startsOf world =
    ( \lines' ->
        [ (start.goal, absPathText start.worktree, start.repo)
        | Started start <- map (.event) lines'
        ]
    )
        <$> logged world

-- | The path of each file artifact logged.
artifactsLogged :: IORef World -> IO [FilePath]
artifactsLogged world =
    ( \lines' ->
        [ absPathText file.ref.path | ArtifactLogged (File file) _ <- map (.event) lines'
        ]
    )
        <$> logged world

-- | What each artifact logged derives from.
artifactParents :: IORef World -> IO [Maybe Natural]
artifactParents world =
    (\lines' -> [from | ArtifactLogged _ from <- map (.event) lines'])
        <$> logged world
