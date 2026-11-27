{- | The e2e scenarios of #360 on the built @state@ binary (@$STATE_BIN@): each
runs in a temp worktree on branch @feat@, whose base @main@ is pushed to a bare
origin, with a scripted @gh@ first on PATH. Scenario 6 drives @state-hook@,
slice C's.
-}
module State.E2ESpec (spec) where

import Concurrently (bothAtOnce)
import Control.Monad (replicateM_, void, (<=<))
import Data.Aeson (Value (..), encode, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Pair)
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.Foldable (for_)
import Data.List (isSuffixOf)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Database.SQLite.Simple qualified as SQLite
import Effects.Store.Connection (Durability (Unsynced), withStore)
import Effects.Store.Events qualified as Store
import State.Artifact (sha256Of, sha256Text)
import State.Category.Fuel (Fuel (Low))
import State.Run.Event (FlowName (TenXFlow), Task (..))
import State.Run.Event qualified as Event
import State.Run.RunGen (
    breakdownJson,
    plainTask,
    refinedTranscript,
    roundTask,
    taskFileJson,
 )
import System.Directory (
    createDirectory,
    createDirectoryIfMissing,
    doesFileExist,
    emptyPermissions,
    findExecutable,
    getPermissions,
    removeFile,
    setOwnerExecutable,
    setPermissions,
 )
import System.Environment (getEnv, getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import Test.Hspec (
    Spec,
    around,
    describe,
    expectationFailure,
    it,
    runIO,
    shouldBe,
    shouldContain,
    shouldSatisfy,
 )

spec :: Spec
spec = describe "the state binary" $ do
    bin <- runIO (getEnv "STATE_BIN")
    hookBin <- runIO (getEnv "STATE_HOOK_BIN")
    around withRepo $ do
        it "runs the engineer flow at Balanced from init to ready" $ \repo -> do
            transcript <- drive bin repo balancedPath
            transcript `shouldBe` balancedTranscript
            done <- succeeded =<< state bin repo ["next"]
            take 5 done
                `shouldBe` [ "DONE " <> prUrl
                           , "  at the end: the flow is done"
                           , "  fuel: balanced"
                           , "  changed lines: 1"
                           , "  PR: " <> prUrl <> " (draft)"
                           ]

        it
            "runs a user's round on an existing PR: GitHub's PR is its draft, unasked, and ready is skipped"
            $ \repo -> do
                _ <- startedIn bin repo ["--notes", repo.notes, "--pr", roundUrlString]
                transcript <- driveOn bin repo roundPath
                transcript `shouldBe` init trivialTranscript <> ["ready.skipped -> out"]
                done <- succeeded =<< state bin repo ["next"]
                take 1 done `shouldBe` ["DONE " <> Text.pack roundUrlString]

        it
            "runs a chief's request on a targeted PR: plan unconfirmed, GitHub's PR its draft, ready skipped"
            $ \repo -> do
                _ <- startedIn bin repo ["--notes", repo.notes, "--flow", "chief"]
                transcript <-
                    driveOn
                        bin
                        repo
                        ( Record ["fuel.set", "low"]
                            : Record ["route.engineer"]
                            : Record ["target", "pr", roundUrlString]
                            : Record ["fuel.set", "low"]
                            : targetedPath
                        )
                transcript
                    `shouldBe` [ "fuel.set -> route"
                               , "route.engineer -> engineer/fuel"
                               , "target -> engineer/fuel"
                               , "engineer/fuel.set -> engineer/gather"
                               ]
                        <> targetedTranscript
                atNext <- succeeded =<< state bin repo ["next"]
                atNext
                    `shouldSatisfy` any (Text.isSuffixOf ("The last result: " <> Text.pack roundUrlString))

        it "asks the user to confirm the next request's plan when it names no target" $ \repo -> do
            _ <- startedIn bin repo ["--notes", repo.notes, "--flow", "chief"]
            _ <-
                driveOn
                    bin
                    repo
                    ( Record ["fuel.set", "low"]
                        : Record ["route.engineer"]
                        : Record ["target", "pr", roundUrlString]
                        : Record ["fuel.set", "low"]
                        : targetedPath
                    )
            transcript <-
                driveOn
                    bin
                    repo
                    ( [ Record ["next.request"]
                      , Record ["fuel.set", "low"]
                      , Record ["route.engineer"]
                      , Record ["fuel.set", "low"]
                      ]
                        <> gathered
                        <> [Planned, Record ["skip_refine.skip"], Record ["present.done"]]
                    )
            transcript
                `shouldBe` [ "next.request -> fuel"
                           , "fuel.set -> route"
                           , "route.engineer -> engineer/fuel"
                           , "engineer/fuel.set -> engineer/gather"
                           , "engineer/gather.enough -> engineer/gather/notes"
                           , "engineer/gather/notes.done -> engineer/plan"
                           , "artifact -> engineer/plan"
                           , "engineer/plan.done -> engineer/skip_refine"
                           , "engineer/skip_refine.skip -> engineer/present"
                           , "engineer/present.done -> engineer/confirm"
                           ]
            asked <- succeeded =<< state bin repo ["next"]
            take 1 asked `shouldSatisfy` all (Text.isInfixOf "confirmed, or adjusted?")

        it
            "walks a chief's architect request: its ticket written, then edited, and enough on to next"
            $ \repo -> do
                _ <- startedIn bin repo ["--notes", repo.notes, "--flow", "chief"]
                transcript <-
                    driveOn
                        bin
                        repo
                        [ Record ["fuel.set", "low"]
                        , Record ["route.architect"]
                        , Record ["fuel.set", "low"]
                        , Record ["architect.ticket"]
                        , Record ["ticket.written", "https://github.com/o/r/issues/3"]
                        , Record ["architect.ticket"]
                        , Record ["ticket.written", "https://github.com/o/r/issues/3"]
                        , Record ["architect.enough"]
                        , Record ["architect/notes.done"]
                        ]
                transcript
                    `shouldBe` [ "fuel.set -> route"
                               , "route.architect -> architect/fuel"
                               , "architect/fuel.set -> architect/architect"
                               , "architect/architect.ticket -> architect/ticket"
                               , "architect/ticket.written -> architect/architect"
                               , "architect/architect.ticket -> architect/ticket"
                               , "architect/ticket.written -> architect/architect"
                               , "architect/architect.enough -> architect/architect/notes"
                               , "architect/architect/notes.done -> next"
                               ]
                atNext <- succeeded =<< state bin repo ["next"]
                atNext
                    `shouldSatisfy` any (Text.isSuffixOf "The last result: https://github.com/o/r/issues/3")

        it "refuses init --pr of no GitHub PR URL in the house format" $ \repo -> do
            refused <-
                state
                    bin
                    repo
                    ["init", "--notes", repo.notes, "--pr", "https://github.com/o/r/issues/7"]
            (refused.code, refused.err)
                `shouldBe` ( 2
                           ,
                               [ "state init: --pr https://github.com/o/r/issues/7 - the PR is a GitHub PR URL, https://github.com/<owner>/<repo>/pull/<n>"
                               , "fix: state init --notes <dir> --pr https://github.com/<owner>/<repo>/pull/<n>"
                               ]
                           )

        it "exits a clean review on to describe, and runs on to ready" $ \repo -> do
            transcript <- drive bin repo cleanPath
            transcript `shouldBe` cleanTranscript
            done <- succeeded =<< state bin repo ["next"]
            take 1 done `shouldBe` ["DONE " <> prUrl]

        it "logs the skips a Low run's agent records for a trivial task" $ \repo -> do
            transcript <- drive bin repo trivialPath
            transcript `shouldBe` trivialTranscript
            done <- succeeded =<< state bin repo ["next"]
            take 1 done `shouldBe` ["DONE " <> prUrl]

        it "refuses an event with no arrow: exit 2, a fix line, and next warns" $ \repo -> do
            _ <- drive bin repo [Record ["fuel.set", "balanced"]]
            refused <- state bin repo ["record", "ready.done", prUrlString]
            (refused.code, refused.err)
                `shouldBe` ( 2
                           ,
                               [ "state record: ready.done - no such arrow out of gather"
                               , "fix: state record gather.enough | state record gather.interview | state record gather.research"
                               ]
                           )
            rows <- dumpOf bin repo =<< runOf bin repo
            [ snd (Text.breakOn "\"data\":" row)
              | row <- rows
              , "\"type\":\"refused\"" `Text.isInfixOf` row
              ]
                `shouldBe` [ "\"data\":{\"code\":\"no_edge\",\"message\":\"ready.done - no such arrow out of gather\",\"fix\":\"state record gather.enough | state record gather.interview | state record gather.research\"}}"
                           ]
            warned <- succeeded =<< state bin repo ["next"]
            take 3 warned
                `shouldBe` [ "RUN one option below"
                           , "refused: ready.done - no such arrow out of gather"
                           , "fix: state record gather.enough | state record gather.interview | state record gather.research"
                           ]
            _ <- succeeded =<< state bin repo ["record", "gather.enough"]
            moved <- succeeded =<< state bin repo ["next"]
            moved `shouldSatisfy` (not . mentions "refused:")

        it
            "refuses an unknown event, listing the gather's picks and fixing it by state next, unlogged"
            $ \repo -> do
                _ <- drive bin repo [Record ["fuel.set", "balanced"]]
                before <- logLines bin repo
                refused <- state bin repo ["record", "gather.bogus"]
                after <- logLines bin repo
                (refused.code, refused.err, after - before)
                    `shouldBe` ( 2
                               ,
                                   [ "state record: no event gather.bogus - at gather the run takes gather.enough, gather.interview, gather.research, extend"
                                   , "fix: state next"
                                   ]
                               , 0
                               )

        it
            "refuses an unknown event with no run, listing every event and fixing it by the help"
            $ \repo -> do
                refused <- state bin repo ["record", "bogus"]
                ( refused.code
                    , map
                        ( Text.isPrefixOf
                            "state record: no event bogus - the events are gap, research.spawned, "
                        )
                        (take 1 refused.err)
                    , drop 1 refused.err
                    )
                    `shouldBe` (2, [True], ["fix: state help"])

        it "takes a question's kind in any case" $ \repo -> do
            _ <- startedRun bin repo
            asked <-
                traverse
                    (\(kind, store) -> state bin repo ["ask", "--kind", kind, "which", store])
                    [("design", "store?"), ("DESIGN", "queue?"), ("Design", "cache?")]
            map (.code) asked `shouldBe` [0, 0, 0]

        it "refuses a ruling's unquoted words, telling to quote them" $ \repo -> do
            (w1, qid) <- childQuestion bin repo
            unquoted <-
                state
                    bin
                    w1
                    [ "rule"
                    , Text.unpack qid
                    , "--answer"
                    , "use"
                    , "Y"
                    , "--why"
                    , "it"
                    , "is"
                    , "simpler"
                    , "--cost"
                    , "none"
                    ]
            (unquoted.code, unquoted.err)
                `shouldBe` ( 2
                           ,
                               [ "state rule: --answer, --why and --cost - each takes one word: quote a longer one"
                               , "fix: state rule " <> qid <> " --answer \"<a>\" --why \"<w>\" --cost \"<c>\""
                               ]
                           )

        it "takes a ruling's quoted words as one answer, why and cost" $ \repo -> do
            (w1, qid) <- childQuestion bin repo
            _ <-
                succeeded
                    =<< state
                        bin
                        w1
                        [ "rule"
                        , Text.unpack qid
                        , "--answer"
                        , "use Y"
                        , "--why"
                        , "it is simpler"
                        , "--cost"
                        , "none"
                        ]
            shown <- succeeded =<< state bin w1 ["show"]
            shown
                `shouldContain` ["  Ruling " <> qid <> " Pick: use Y - it is simpler - none"]

        it "refuses a question id that is not open, listing the open ones" $ \repo -> do
            run <- startedRun bin repo
            qid <- askedQid bin repo "Design" ["which", "store?"]
            refused <-
                traverse
                    (\raw -> state bin repo ["forward", raw])
                    ["q1", Text.unpack run <> ":99"]
            [ ( ran.code
              , drop 1 (Text.splitOn " - " (Text.concat (take 1 ran.err)))
              , drop 1 ran.err
              )
              | ran <- refused
              ]
                `shouldBe` replicate 2 (2, ["it is not open; open: " <> qid], ["fix: state pending"])

        it
            "keeps a file's snapshot past its deletion: handover re-registers the edited one, skips the deleted one"
            $ \repo -> do
                run <- Text.unpack <$> startedRun bin repo
                writeFile (repo.work </> "notes.md") "v1\n"
                writeFile (repo.work </> "b.md") "b\n"
                _ <- succeeded =<< state bin repo ["artifact", "notes.md", "--kind", "notes"]
                _ <- succeeded =<< state bin repo ["artifact", "b.md", "--kind", "notes"]
                writeFile (repo.work </> "notes.md") "v2\n"
                removeFile (repo.work </> "b.md")
                handedOver <-
                    succeeded
                        =<< state
                            bin
                            repo
                            ["handover", "--reason", "context", "--summary", "s", "--next", "go on"]
                removeFile (repo.work </> "notes.md")
                newer <- succeeded =<< state bin repo ["artifact", "show", run <> ":4"]
                original <- succeeded =<< state bin repo ["artifact", "show", run <> ":3"]
                ( any ("skipped " `Text.isPrefixOf`) handedOver
                    , any
                        (Text.isSuffixOf "b.md: gone or unreadable, its last snapshot kept")
                        handedOver
                    , newer
                    , original
                    )
                    `shouldBe` (True, True, ["v2"], ["b"])

        it
            "resumes from a file's snapshot past its deletion: register, delete, hand over, resume, show"
            $ \repo -> do
                run <- startedRun bin repo
                let notes = repo.work </> "notes.md"
                writeFile notes "v1\n"
                _ <- succeeded =<< state bin repo ["artifact", "notes.md", "--kind", "notes"]
                removeFile notes
                _ <-
                    succeeded
                        =<< state
                            bin
                            repo
                            ["handover", "--reason", "context", "--summary", "s", "--next", "go on"]
                resumed <- succeeded =<< state bin repo ["resume"]
                shown <-
                    succeeded =<< state bin repo ["artifact", "show", Text.unpack run <> ":2"]
                ( filter (Text.isPrefixOf "notes " . Text.strip) resumed
                    , filter (Text.isInfixOf "load: state artifact show") resumed
                    , filter (Text.isPrefixOf "  1. ") resumed
                    , shown
                    )
                    `shouldBe` (
                                   [ "    notes "
                                        <> run
                                        <> ":2 "
                                        <> Text.pack notes
                                        <> " sha256:"
                                        <> sha256Text (sha256Of "v1\n")
                                        <> " 3 bytes stored"
                                   ]
                               , ["      load: state artifact show " <> run <> ":2"]
                               , ["  1. go on"]
                               , ["v1"]
                               )

        it "resumes a moved run at its new worktree" $ \repo -> do
            _ <- startedRun bin repo
            target <- worktree repo "target"
            top <- Text.strip . Text.pack <$> gitOut target ["rev-parse", "--show-toplevel"]
            _ <- succeeded =<< state bin repo ["move", target.work]
            resumed <- succeeded =<< state bin target ["resume"]
            filter (Text.isPrefixOf "worktree: ") resumed
                `shouldBe` ["worktree: " <> top <> "   repo: none   fuel: balanced"]

        it
            "logs a plan.done whose plan may not be read, with no artifact, and names the path"
            $ \repo -> do
                _ <- drive bin repo (Record ["fuel.set", "balanced"] : gathered)
                let plan = repo.work </> "plan.md"
                writeFile plan "the plan"
                setPermissions plan emptyPermissions
                ran <- succeeded =<< state bin repo ["record", "plan.done", plan]
                (take 1 ran, filter ("recorded " `Text.isPrefixOf`) ran)
                    `shouldBe` (
                                   [ "file_unreadable "
                                        <> Text.pack plan
                                        <> ": gone or unreadable, no artifact logged"
                                   ]
                               , ["recorded 5 plan.done -> skip_refine"]
                               )

        it
            "closes a researcher's child as it returns with its report, which has no token, so the waiting gather goes on to its notes"
            $ \repo -> do
                _ <-
                    drive
                        bin
                        repo
                        [ Record ["fuel.set", "balanced"]
                        , Record ["gather.research"]
                        , Spawn "researcher"
                        ]
                enough <- succeeded =<< state bin repo ["record", "gather.enough"]
                back <-
                    succeeded
                        =<< hook hookBin repo "handback" (reportedBack repo "researcher" researched)
                (recorded enough, back) `shouldSatisfy` \case
                    (["gather.enough -> gather/researchers"], [reply]) ->
                        all
                            (`Text.isInfixOf` reply)
                            [ "gather/research.handed_back -> gather/researchers"
                            , "worker_returned -> gather/notes"
                            ]
                    _ -> False

        it "prints each record it advises with its arguments" $ \repo -> do
            _ <- drive bin repo (Record ["fuel.set", "balanced"] : gathered)
            advice <- succeeded =<< state bin repo ["next"]
            take 1 advice `shouldBe` ["RUN state record plan.done <path>"]

        it "prints the run's id, notes dir and worktree top, one line a hook parses" $ \repo -> do
            top <- Text.strip . Text.pack <$> gitOut repo ["rev-parse", "--show-toplevel"]
            started@[said, _, _] <-
                succeeded =<< state bin repo ["init", "--notes", repo.notes <> "/"]
            let run = Text.drop (Text.length "started ") said
            resumed <- succeeded =<< state bin repo ["init", "--notes", repo.notes]
            (started, resumed)
                `shouldBe` (
                               [ "started " <> run
                               , "run " <> run <> " " <> Text.pack repo.notes <> " " <> top
                               , "next: state next"
                               ]
                           ,
                               [ "resumed " <> run
                               , "run " <> run <> " " <> Text.pack repo.notes <> " " <> top
                               , "next: state next"
                               ]
                           )

        it "refuses another run over the worktree's unfinished one" $ \repo -> do
            run <- startedRun bin repo
            other <- state bin repo ["init", "--notes", repo.root </> "other"]
            (other.code, other.err)
                `shouldBe` ( 2
                           ,
                               [ "state init: --notes "
                                    <> Text.pack (repo.root </> "other")
                                    <> " - the worktree holds unfinished run "
                                    <> run
                                    <> " in "
                                    <> Text.pack repo.notes
                               , "fix: state next goes on with it, a branch inline in it, or state stop <reason> <why> ends it"
                               ]
                           )

        it "refuses a relative notes dir" $ \repo -> do
            relative <- state bin repo ["init", "--notes", "notes"]
            (relative.code, take 1 relative.err)
                `shouldBe` ( 2
                           ,
                               [ "state init: --notes notes - the notes dir is an absolute path of ASCII letters, digits and ._/@+-"
                               ]
                           )

        it "starts a run once per notes dir, and refuses one there after it stopped" $ \repo -> do
            run <- startedRun bin repo
            again <- succeeded =<< state bin repo ["init", "--notes", repo.notes]
            take 1 again `shouldBe` ["resumed " <> run]
            _ <-
                succeeded =<< state bin repo ["stop", "replan", "the", "plan", "is", "wrong"]
            refused <- state bin repo ["init", "--notes", repo.notes]
            (refused.code, drop 1 refused.err)
                `shouldBe` (2, ["fix: state init --notes <a new dir>"])

        it
            "fixes a refused event by the arrows this Fuel takes, never a skip it refuses"
            $ \repo -> do
                _ <- drive bin repo toSimplifyPr
                refused <- state bin repo ["record", "await_ci.green"]
                (refused.code, refused.err)
                    `shouldBe` ( 2
                               ,
                                   [ "state record: await_ci.green - no such arrow out of simplify_pr"
                                   , "fix: state record simplify_pr.done"
                                   ]
                               )

        it "overrides to a named state" $ \repo -> do
            _ <- drive bin repo []
            moved <-
                succeeded
                    =<< state bin repo ["override", "review", "resume", "after", "a", "crash"]
            moved `shouldBe` ["recorded 2 overridden -> review", "next: state next"]
            shown <- succeeded =<< state bin repo ["show"]
            shown `shouldContain` ["step: review"]

        it "refuses an override to an unknown state, listing the states" $ \repo -> do
            _ <- drive bin repo []
            refused <- state bin repo ["override", "nowhere", "why"]
            (refused.code, refused.err)
                `shouldBe` ( 2
                           ,
                               [ "state override: override to nowhere - the flow has no single state of that name"
                               , "fix: state override <fuel|gather|gather/researchers|gather/notes|gather/research|interview|plan|skip_refine|simplify_plan|standards_plan|align_plan|present|confirm|draft|implement|skip_refactor|refactor|review|pick|fix|re_review|describe|visual|simplify_pr|await_ci|fix_pr|ready> <why>"
                               ]
                           )

        it
            "voids a line, the run replaying as if it was never logged, and refuses it voided again"
            $ \repo -> do
                _ <- drive bin repo []
                _ <-
                    succeeded
                        =<< state bin repo ["override", "review", "resume", "after", "a", "crash"]
                voided <-
                    succeeded =<< state bin repo ["void", "2", "overridden", "in", "error"]
                shown <- succeeded =<< state bin repo ["show"]
                again <- state bin repo ["void", "2", "again"]
                (voided, "step: review" `elem` shown, again.code, again.err)
                    `shouldBe` ( ["recorded 3 voided -> fuel", "next: state next"]
                               , False
                               , 2
                               ,
                                   [ "state void: seq 2 - no line the run replays has it: none does, it is voided, or it is a void"
                                   , "fix: state void <the seq of an event state dump prints> <why>"
                                   ]
                               )

        it
            "moves a run started in the wrong worktree: next and the agent's calls go there, not to the old one"
            $ \repo -> do
                run <- initBound bin hookBin repo Null repo ["--notes", repo.notes]
                target <- worktree repo "target"
                top <- Text.strip . Text.pack <$> gitOut target ["rev-parse", "--show-toplevel"]
                moved <- succeeded =<< state bin repo ["move", target.work]
                old <- state bin repo ["next"]
                there <- succeeded =<< state bin target ["show"]
                routedOld <-
                    succeeded =<< hook hookBin repo "route" (ranIn repo Null "state next")
                routedThere <-
                    succeeded
                        =<< hook
                            hookBin
                            repo
                            "route"
                            (ranIn repo Null ("cd " <> Text.pack target.work <> " && state next"))
                (moved, old.code, take 1 there, replyField "decision" routedOld, routedThere)
                    `shouldBe` ( ["moved " <> run <> " to " <> top, "next: state next"]
                               , 2
                               , ["run: " <> run <> " (engineer)"]
                               , Just "deny"
                               , []
                               )

        it
            "refuses a move to no worktree, to this worktree, and to one holding an unfinished run"
            $ \repo -> do
                _ <- startedRun bin repo
                target <- worktree repo "target"
                other <- startedIn bin target ["--notes", repo.root </> "other"]
                refused <-
                    traverse
                        (\dir -> state bin repo ["move", dir])
                        [repo.root, repo.work, target.work]
                map (\ran -> (ran.code, take 1 ran.err)) refused
                    `shouldBe` [
                                   ( 2
                                   ,
                                       [ "state move: "
                                            <> Text.pack repo.root
                                            <> " is in no git worktree - git finds none there"
                                       ]
                                   )
                               ,
                                   ( 2
                                   ,
                                       [ "state move: "
                                            <> Text.pack repo.work
                                            <> " - it is this worktree, which holds the run already"
                                       ]
                                   )
                               ,
                                   ( 2
                                   ,
                                       [ "state move: "
                                            <> Text.pack target.work
                                            <> " - its worktree holds unfinished run "
                                            <> other
                                            <> " in "
                                            <> Text.pack (repo.root </> "other")
                                       ]
                                   )
                               ]

        it "names a hand-edited bad event and appends nothing after it" $ \repo -> do
            _ <- drive bin repo []
            run <- runOf bin repo
            appendByHand repo run 2 olderEvent
            before <- storedRows repo run
            for_ [("next", []), ("show", []), ("record", ["fuel.set", "max"])] $ \(sub, args) -> do
                bad <- state bin repo (sub : args)
                (bad.code, bad.err)
                    `shouldBe` ( 2
                               ,
                                   [ "state "
                                        <> Text.pack sub
                                        <> ": run "
                                        <> run
                                        <> " has an event this state cannot read - seq 2, type fuel (schema_version 2)"
                                   , "fix: upgrade state"
                                   ]
                               )
            after <- storedRows repo run
            after `shouldBe` before

        it "dumps a row it cannot read raw, its columns as stored" $ \repo -> do
            _ <- drive bin repo []
            run <- runOf bin repo
            appendByHand repo run 2 olderEvent
            rows <- dumpOf bin repo run
            drop 1 rows
                `shouldBe` [ "{\"run_id\":\""
                                <> run
                                <> "\",\"seq\":2,\"schema_version\":2,\"type\":\"fuel\",\"time\":\"2025-11-21T00:00:00.000Z\",\"session_id\":null,\"head_sha\":null,\"hook_digest\":null,\"data\":{}}"
                           ]

        it "keeps kernel.db byte for byte, its runs written to kernel-v2.db" $ \repo -> do
            let old = takeDirectory (storeOf repo) </> "kernel.db"
                bytes = "SQLite format 3\NULan older kernel's store"
            createDirectoryIfMissing True (takeDirectory old)
            LBS8.writeFile old bytes
            _ <- drive bin repo []
            _ <- succeeded =<< state bin repo ["record", "gap", "a gap"]
            _ <- succeeded =<< state bin repo ["void", "2", "logged", "in", "error"]
            types <- loggedTypes bin repo
            stored <- doesFileExist (storeOf repo)
            kept <- LBS8.readFile old
            (types, stored, kept) `shouldBe` (["started", "gap", "voided"], True, bytes)

        it "loses no event of two state processes appending to one run at once" $ \repo -> do
            _ <- drive bin repo []
            before <- logLines bin repo
            let perProcess = 10
                -- Each call appends one event: a gap never moves the run.
                appending = replicateM_ perProcess (void (state bin repo ["record", "gap", "a gap"]))
            bothAtOnce appending appending
            seqs <- mapMaybe (column "seq") <$> dumped bin repo
            seqs `shouldBe` map (Number . fromIntegral) [1 .. before + 2 * perProcess]

        it
            "records a child's parent run, and the store lists it among the parent's children"
            $ \repo -> do
                parent <- tenXAtFanOut bin repo
                w1 <- worktree repo "w1"
                child <- childRun bin w1 parent "n1" "t1"
                listed <-
                    withStore
                        Unsynced
                        (storeOf repo)
                        (`Store.children` parent)
                listed `shouldBe` Right [child]

        it
            "pauses the chief's architect request, answers an engineer child's question meanwhile, and turns back to the architect at the same node"
            $ \repo -> do
                parent <- startedIn bin repo ["--notes", repo.notes, "--flow", "chief"]
                for_
                    [["record", "fuel.set", "balanced"], ["record", "route.architect"]]
                    (succeeded <=< state bin repo)
                shownBefore <- succeeded =<< state bin repo ["show"]
                away <-
                    succeeded =<< state bin repo ["focus", "--summary", "the architect gathers"]
                w1 <- worktree repo "w1"
                child <- directChild bin w1 parent "n1"
                qid <- askedQid bin w1 "Design" ["which", "store?"]
                _ <- succeeded =<< state bin w1 ["next"]

                _ <- succeeded =<< state bin repo ["answer", Text.unpack qid, "postgres"]
                answered <- succeeded =<< state bin w1 ["show"]
                listed <- succeeded =<< state bin repo ["tasks"]
                _ <- succeeded =<< state bin repo ["focus", "r1"]
                shownAfter <- succeeded =<< state bin repo ["show"]

                away `shouldSatisfy` mentions "r2 in focus at fuel"
                answered `shouldSatisfy` mentions (qid <> " Design: which store? - postgres")
                listed `shouldSatisfy` mentions ("child " <> child <> " engineer at ")
                filter ("step:" `Text.isPrefixOf`) shownAfter
                    `shouldBe` filter ("step:" `Text.isPrefixOf`) shownBefore

        it
            "answers one direct child's question from the chief's run, which forwards a Design; only that child resumes, its sibling runs on unaffected"
            $ \repo -> do
                parent <- startedIn bin repo ["--notes", repo.notes, "--flow", "chief"]
                w1 <- worktree repo "w1"
                w2 <- worktree repo "w2"
                asking <- directChild bin w1 parent "n1"
                sibling <- directChild bin w2 parent "n2"
                qid <- askedQid bin w1 "Design" ["which", "store?"]
                waiting <- succeeded =<< state bin w1 ["next"]
                moved <- succeeded =<< state bin w2 ["record", "fuel.set", "low"]
                siblingAsked <- succeeded =<< state bin w2 ["next"]
                pending <- succeeded =<< state bin repo ["pending"]

                _ <- succeeded =<< state bin repo ["answer", Text.unpack qid, "postgres"]
                resumed <- succeeded =<< state bin w1 ["next"]
                siblingRuled <- succeeded =<< state bin w2 ["next"]
                shownAsking <- succeeded =<< state bin w1 ["show"]
                shownSibling <- succeeded =<< state bin w2 ["show"]
                listed <-
                    withStore
                        Unsynced
                        (storeOf repo)
                        (`Store.children` parent)

                listed `shouldBe` Right [asking, sibling]
                take 1 waiting
                    `shouldSatisfy` all ("HANDBACK NEEDS_DECISION Design " `Text.isPrefixOf`)
                recorded moved `shouldBe` ["fuel.set -> gather"]
                pending `shouldSatisfy` mentions qid
                take 1 resumed `shouldBe` ["RUN state record fuel.set <low|balanced|max>"]
                shownAsking `shouldSatisfy` mentions (qid <> " Design: which store? - postgres")
                siblingRuled `shouldBe` siblingAsked
                shownSibling `shouldSatisfy` (not . mentions qid)

        describe "the review loop" $ do
            it "asks Stuck when rounds 1 and 2 pick the same row" $ \repo -> do
                _ <-
                    drive
                        bin
                        repo
                        ( atReview
                            <> reviewRound "R1" []
                            <> [Handback "fixer" ready]
                            <> reviewRound "R1" []
                        )
                advice <- succeeded =<< state bin repo ["next"]
                take 1 advice
                    `shouldBe` ["ASK Stuck the fix loop repeats R1: go on, change course, or stop?"]

            it
                "offers a stuck loop's exit once Stuck was asked, and takes it to describe with no override"
                $ \repo -> do
                    _ <-
                        drive
                            bin
                            repo
                            ( atReview
                                <> reviewRound "R1" []
                                <> [Handback "fixer" ready]
                                <> reviewRound "R1" []
                                <> [AskUser "Stuck" ["stop?"]]
                            )
                    advice <- succeeded =<< state bin repo ["next"]
                    filter ("pick.final" `Text.isInfixOf`) advice
                        `shouldBe` [ "    state record pick.final [--row <label>]... [--verdict <requirement>=<met|not-met|unverified>]... - on to describe"
                                   ]
                    exited <- succeeded =<< state bin repo ["record", "pick.final", "--row", "R1"]
                    recorded exited `shouldBe` ["pick.final -> describe"]

            it "refuses a pick.loop past Balanced's 3 re-reviews, then exits by pick.final" $ \repo -> do
                let rounds =
                        concat
                            [reviewRound label [] <> [Handback "fixer" ready] | label <- ["R1", "R2", "R3"]]
                _ <- drive bin repo (atReview <> rounds <> [Handback "review-lead" reviewed])
                advice <- succeeded =<< state bin repo ["next"]
                (take 1 advice, filter ("  Re-reviews: " `Text.isPrefixOf`) advice)
                    `shouldBe` (
                                   [ "RUN state record pick.final [--row <label>]... [--verdict <requirement>=<met|not-met|unverified>]..."
                                   ]
                               , ["  Re-reviews: 3 of 3 used, none left"]
                               )
                refused <- state bin repo ["record", "pick.loop", "--row", "R4"]
                (refused.code, refused.err)
                    `shouldBe` ( 2
                               ,
                                   [ "state record: the spend at pick - Re-reviews allows 3 at this Fuel, all spent"
                                   , "fix: state record pick.final [--row <label>]... [--verdict <requirement>=<met|not-met|unverified>]..."
                                   ]
                               )
                exited <- succeeded =<< state bin repo ["record", "pick.final"]
                recorded exited `shouldBe` ["pick.final -> describe"]

        describe "audit" $ do
            it "puts every ruling of a child run in show and in its hand-back" $ \repo -> do
                parent <- tenXAtFanOut bin repo
                w1 <- worktree repo "w1"
                child <- childRun bin w1 parent "child" "t1"
                qid <- askedQid bin w1 "Pick" ["which", "lib?"]
                let ruling = "Ruling " <> qid <> " Pick: zod - already used - none"
                _ <-
                    succeeded
                        =<< state
                            bin
                            w1
                            [ "rule"
                            , Text.unpack qid
                            , "--answer"
                            , "zod"
                            , "--why"
                            , "already used"
                            , "--cost"
                            , "none"
                            ]
                shown <- succeeded =<< state bin w1 ["show"]
                shown `shouldContain` ["rulings:", "  " <> ruling]
                forwarded <-
                    succeeded =<< state bin w1 ["ask", "--kind", "Design", "which", "store?"]
                forwarded `shouldContain` [ruling]
                stopped <- succeeded =<< state bin w1 ["stop", "failed", "no", "access"]
                stopped
                    `shouldBe` ["stopped", "HANDBACK FAILED no access", "Run: " <> child, ruling]

        describe "the 10x" $ do
            it
                "rules one child's question, forwards the other's Security question, and resumes both"
                $ \repo -> do
                    parent <- tenXAtFanOut bin repo
                    w1 <- worktree repo "w1"
                    w2 <- worktree repo "w2"
                    c1 <- childRun bin w1 parent "n1" "t1"
                    c2 <- childRun bin w2 parent "n2" "t2"
                    q1 <- Text.unpack <$> askedQid bin w1 "Design" ["which", "store?"]
                    q2 <- Text.unpack <$> askedQid bin w2 "Security" ["token", "in", "env?"]
                    _ <-
                        succeeded
                            =<< state
                                bin
                                repo
                                ["rule", q1, "--answer", "postgres", "--why", "already used", "--cost", "none"]
                    unfounded <-
                        state
                            bin
                            repo
                            ["rule", q2, "--answer", "yes", "--why", "fine", "--cost", "none"]
                    unfounded.code `shouldBe` 2
                    _ <- succeeded =<< state bin repo ["forward", q2]
                    first <- succeeded =<< state bin repo ["next"]
                    take 1 first
                        `shouldBe` ["RESUME " <> c1 <> " with the answer to " <> Text.pack q1 <> ": postgres"]
                    _ <- succeeded =<< state bin repo ["record", "resumed", Text.unpack c1]
                    userHolds <- succeeded =<< state bin repo ["next"]
                    map
                        (("ASK Security " <> Text.pack q2 <> ": token in env? - ") `Text.isPrefixOf`)
                        (take 1 userHolds)
                        `shouldBe` [True]
                    _ <- succeeded =<< state bin repo ["answer", q2, "use", "a", "vault"]
                    second <- succeeded =<< state bin repo ["next"]
                    take 1 second
                        `shouldBe` ["RESUME " <> c2 <> " with the answer to " <> Text.pack q2 <> ": use a vault"]
                    _ <- succeeded =<< state bin repo ["record", "resumed", Text.unpack c2]
                    twice <- state bin repo ["record", "resumed", Text.unpack c2]
                    twice.code `shouldBe` 2
                    -- Each answer was written down to the child that asked it.
                    shown1 <- succeeded =<< state bin w1 ["show"]
                    shown2 <- succeeded =<< state bin w2 ["show"]
                    shown1
                        `shouldSatisfy` mentions (Text.pack q1 <> " Design: which store? - postgres")
                    shown2
                        `shouldSatisfy` mentions (Text.pack q2 <> " Security: token in env? - use a vault")
                    -- The child's own answer, the same, adds nothing; another is refused.
                    _ <-
                        succeeded
                            =<< state bin w1 ["answer", q1, "postgres", "--by", Text.unpack parent]
                    other <- state bin w1 ["answer", q1, "sqlite", "--by", Text.unpack parent]
                    other.code `shouldBe` 2
                    relay bin repo ["HANDBACK READY " <> prUrl, "Run: " <> c1]
                    third <- succeeded =<< state bin repo ["next"]
                    take 1 third `shouldBe` ["AWAIT children t2"]

            it "asks the user its own breakdown Confirm, and refuses to rule on it" $ \repo -> do
                _ <- startedIn bin repo ["--notes", repo.notes, "--flow", "10x"]
                for_
                    [["override", "confirm", "the", "plan", "is", "written"]]
                    (succeeded <=< state bin repo)
                asked <-
                    succeeded
                        =<< state bin repo ["ask", "--kind", "Confirm", "start", "the", "breakdown?"]
                asked `shouldSatisfy` mentions "ASK user"
                ruled <-
                    state
                        bin
                        repo
                        [ "rule"
                        , Text.unpack (Text.drop (Text.length "asked ") (Text.concat (take 1 asked)))
                        , "--answer"
                        , "yes"
                        , "--why"
                        , "fits"
                        , "--cost"
                        , "none"
                        ]
                ruled.code `shouldBe` 2

            it "rules a child's task-plan Confirm" $ \repo -> do
                parent <- tenXAtFanOut bin repo
                w1 <- worktree repo "w1"
                c1 <- childRun bin w1 parent "n1" "t1"
                qid <- askedQid bin w1 "Confirm" ["the", "plan", "holds?"]
                _ <-
                    succeeded
                        =<< state
                            bin
                            repo
                            [ "rule"
                            , Text.unpack qid
                            , "--answer"
                            , "confirmed"
                            , "--why"
                            , "fits t1"
                            , "--cost"
                            , "none"
                            ]
                resume <- succeeded =<< state bin repo ["next"]
                take 1 resume
                    `shouldBe` ["RESUME " <> c1 <> " with the answer to " <> qid <> ": confirmed"]

            it "refuses a malformed task file with the breakdown's error" $ \repo -> do
                _ <- tenXAtFanOut bin repo
                malformed <- taskAdded bin repo "{\"id\": \"fix\"}"
                (malformed.code, malformed.err) `shouldSatisfy` \(code, err) -> code == 2 && mentions "key \"deps\" not found" err

            it "adds a task mid-run and spawns it" $ \repo -> do
                _ <- tenXAtFanOut bin repo
                _ <- succeeded =<< taskAdded bin repo (taskFileJson (plainTask "fix" []))
                _ <- succeeded =<< state bin repo ["record", "spawning", "t1"]
                spawn <- succeeded =<< state bin repo ["next"]
                take 1 spawn `shouldBe` ["SPAWN engineer --task fix background: yes"]

            it
                "spawns a task once: next waits on it from the recorded spawn, before the child starts"
                $ \repo -> do
                    _ <- tenXAtFanOut bin repo
                    spawn <- succeeded =<< state bin repo ["next"]
                    take 1 spawn `shouldBe` ["SPAWN engineer --task t1 background: yes"]
                    _ <- succeeded =<< state bin repo ["record", "spawning", "t1"]
                    waits <- succeeded =<< state bin repo ["next"]
                    take 1 waits `shouldBe` ["AWAIT children t1"]
                    twice <- state bin repo ["record", "spawning", "t1"]
                    twice.code `shouldBe` 2

            it
                "records a child's stop in its run once, a repeated next adding nothing, and triages it"
                $ \repo -> do
                    parent <- tenXAtFanOut bin repo
                    w1 <- worktree repo "w1"
                    c1 <- childRun bin w1 parent "n1" "t1"
                    _ <- succeeded =<< state bin w1 ["stop", "failed", "no", "access"]
                    once <- logLines bin repo
                    _ <- succeeded =<< state bin w1 ["next"]
                    again <- logLines bin repo
                    triage <- succeeded =<< state bin repo ["next"]
                    again `shouldBe` once
                    take 1 triage
                        `shouldBe` [ "RUN state retry t1 --why <w> | state ask --kind <kind> --from "
                                        <> c1
                                        <> " <question> - triage: FAILED no access"
                                   ]

            it
                "leaves a child's recorded hand-back be once its parent moved past the fan-out"
                $ \repo -> do
                    parent <- tenXAtFanOut bin repo
                    writeFile repo.prJson (pullRequest True "OPEN")
                    w1 <- worktree repo "w1"
                    _ <- childRun bin w1 parent "n1" "t1"
                    for_
                        [ ["override", "await_ci", "the", "test", "starts", "here"]
                        , ["record", "await_ci.green"]
                        , ["record", "ready.done", prUrlString]
                        ]
                        (succeeded <=< state bin w1)
                    _ <- succeeded =<< state bin w1 ["next"]
                    _ <-
                        succeeded
                            =<< state bin repo ["record", "task", "t2", "parked", "out", "of", "scope"]
                    _ <- succeeded =<< state bin repo ["next"]
                    once <- logLines bin repo
                    again <- succeeded =<< state bin w1 ["next"]
                    after <- logLines bin repo
                    (after, filter (Text.isPrefixOf "parent: ") again) `shouldBe` (once, [])

            it
                "tells a child its parent off the fan-out refused its hand-back, and the parent's next names it back there"
                $ \repo -> do
                    parent <- tenXAtFanOut bin repo
                    writeFile repo.prJson (pullRequest True "OPEN")
                    w1 <- worktree repo "w1"
                    c1 <- childRun bin w1 parent "n1" "t1"
                    for_
                        [ ["override", "await_ci", "the", "test", "starts", "here"]
                        , ["record", "await_ci.green"]
                        , ["record", "ready.done", prUrlString]
                        ]
                        (succeeded <=< state bin w1)
                    _ <-
                        succeeded
                            =<< state
                                bin
                                repo
                                ["override", "breakdown", "the", "test", "leaves", "the", "fan-out"]
                    refused <- succeeded =<< state bin w1 ["next"]
                    _ <-
                        succeeded =<< state bin repo ["override", "engineers", "the", "test", "returns"]
                    named <- succeeded =<< state bin repo ["next"]
                    refused `shouldSatisfy` mentions "parent: "
                    take 1 named `shouldBe` ["RUN state handback engineer"]
                    named
                        `shouldContain` [ "    state handback engineer - child "
                                            <> c1
                                            <> " ended, its hand-back unrecorded: pipe it in"
                                        ]

            it "triages a child's stop before it retries the task" $ \repo -> do
                parent <- tenXAtFanOut bin repo
                w1 <- worktree repo "w1"
                c1 <- childRun bin w1 parent "n1" "t1"
                relay bin repo ["HANDBACK BLOCKED no access to the registry", "Run: " <> c1]
                triage <- succeeded =<< state bin repo ["next"]
                take 1 triage
                    `shouldBe` [ "RUN state retry t1 --why <w> | state ask --kind <kind> --from "
                                    <> c1
                                    <> " <question> - triage: BLOCKED no access to the registry"
                               ]
                qid <-
                    askedQid
                        bin
                        repo
                        "Stuck"
                        ["--from", Text.unpack c1, "retry", "with", "a", "token?"]
                _ <-
                    succeeded
                        =<< state
                            bin
                            repo
                            [ "rule"
                            , Text.unpack qid
                            , "--answer"
                            , "retry"
                            , "--why"
                            , "first try"
                            , "--cost"
                            , "one try"
                            ]
                retry <- succeeded =<< state bin repo ["next"]
                take 1 retry `shouldBe` ["SPAWN engineer --task t1 background: yes"]

            it "retries a stopped child's task under a fresh notes dir, once" $ \repo -> do
                parent <- startedIn bin repo ["--notes", repo.notes, "--flow", "10x"]
                let tasks = repo.root </> "tasks.json"
                Text.writeFile
                    tasks
                    (breakdownJson [(plainTask "t1" []) {repo = Just (Event.Repo "o" "r")}])
                for_
                    [ ["override", "breakdown", "the", "plan", "is", "agreed"]
                    , ["record", "breakdown.done", "--tasks", tasks]
                    ]
                    (succeeded <=< state bin repo)
                first <- succeeded =<< state bin repo ["brief", "engineer", "--task", "t1"]
                w1 <- worktree repo "w1"
                c1 <- childRun bin w1 parent "n1" "t1"
                relay bin repo ["HANDBACK BLOCKED no access to the registry", "Run: " <> c1]
                retry <-
                    succeeded =<< state bin repo ["retry", "t1", "--why", "the token is set now"]
                spawn <- succeeded =<< state bin repo ["next"]
                w2 <- worktree repo "w2"
                c2 <- childRun bin w2 parent "n2" "t1"
                relay bin repo ["HANDBACK BLOCKED no access still", "Run: " <> c2]
                capped <- state bin repo ["retry", "t1", "--why", "once more"]
                triage <- succeeded =<< state bin repo ["next"]
                first
                    `shouldSatisfy` mentions ("state init --notes /tmp/engineer-o-r-t1/ --parent " <> parent)
                retry
                    `shouldSatisfy` mentions ("state init --notes /tmp/engineer-o-r-t1-t2/ --parent " <> parent)
                take 1 spawn `shouldBe` ["SPAWN engineer --task t1 background: yes"]
                (capped.code, take 1 capped.err)
                    `shouldBe` (2, ["state retry: task t1 - 2 children tried it, its one retry is spent"])
                take 1 triage
                    `shouldBe` [ "RUN state ask --kind <kind> --from "
                                    <> c2
                                    <> " <question> - triage: BLOCKED no access still"
                               ]

            it "refuses a retry of a task with no stopped child to triage" $ \repo -> do
                _ <- childAtWork bin repo
                refused <- state bin repo ["retry", "t1", "--why", "a guess"]
                (refused.code, refused.err)
                    `shouldBe` ( 2
                               ,
                                   [ "state retry: task t1 - no stopped child of it awaits triage"
                                   , "fix: state next"
                                   ]
                               )

            it "lists, after a crash, the child still running and the question pending" $ \repo -> do
                parent <- tenXAtFanOut bin repo
                w1 <- worktree repo "w1"
                w2 <- worktree repo "w2"
                c1 <- childRun bin w1 parent "n1" "t1"
                c2 <- childRun bin w2 parent "n2" "t2"
                qid <- askedQid bin w2 "Design" ["which", "store?"]
                advice <- succeeded =<< state bin repo ["next"]
                qid `shouldSatisfy` ((c2 <> ":") `Text.isPrefixOf`)
                take 1 advice `shouldSatisfy` mentions ("state rule " <> qid)
                advice `shouldContain` ["  task t1: child " <> c1 <> " running, tries 1"]

            it
                "awaits CI a child hands back, then leaves the fan-out once the child is ready"
                $ \repo -> do
                    parent <- tenXAtFanOut bin repo
                    writeFile repo.prJson (pullRequest True "OPEN")
                    w1 <- worktree repo "w1"
                    _ <- childRun bin w1 parent "n1" "t1"
                    for_
                        [["override", "await_ci", "the", "test", "starts", "here"]]
                        (succeeded <=< state bin w1)
                    _ <- succeeded =<< state bin w1 ["next"]
                    _ <-
                        succeeded
                            =<< state bin repo ["record", "task", "t2", "parked", "out", "of", "scope"]
                    awaiting <- succeeded =<< state bin repo ["next"]
                    take 1 awaiting `shouldBe` ["AWAIT ci " <> prUrl]
                    for_ [["await_ci.green"], ["ready.done", prUrlString]] $ \argv -> succeeded =<< state bin w1 ("record" : argv)
                    _ <- succeeded =<< state bin w1 ["next"]
                    left <- succeeded =<< state bin repo ["next"]
                    recorded left `shouldBe` []
                    left `shouldSatisfy` mentions "AWAIT merge t1"
                    early <- state bin repo ["record", "merge.done", prUrlString]
                    early.code `shouldBe` 2
                    _ <-
                        succeeded =<< state bin repo ["record", "task", "t1", "merged", prUrlString]
                    done <- succeeded =<< state bin repo ["next"]
                    take 1 done `shouldBe` ["RUN one option below"]
                    done
                        `shouldContain` [ "  options:"
                                        , "    state record merge.done <url> - the flow ends"
                                        , "    state record merge.next_round - back to gather, the round loop's next round"
                                        ]

            it
                "awaits a finished task's CI after a fixer's push, and leaves the fan-out only once it is in review"
                $ \repo -> do
                    parent <- tenXAtFanOut bin repo
                    w1 <- worktree repo "w1"
                    c1 <- childRun bin w1 parent "n1" "t1"
                    _ <-
                        succeeded
                            =<< stateIn
                                bin
                                repo
                                (Text.unpack (Text.unlines ["READY " <> prUrl, "Run: " <> c1]))
                                ["handback", "engineer"]
                    for_
                        [ ["task", "t1", "ci", prUrlString]
                        , ["task", "t2", "parked", "out", "of", "scope"]
                        ]
                        (succeeded <=< state bin repo . ("record" :))
                    waits <- succeeded =<< state bin repo ["next"]
                    (recorded waits, take 1 waits) `shouldBe` ([], ["AWAIT ci " <> prUrl])
                    _ <-
                        succeeded =<< state bin repo ["record", "task", "t1", "review", prUrlString]
                    left <- succeeded =<< state bin repo ["next"]
                    recorded left `shouldBe` []

            it
                "prints a line per task it can act on: the resume first, then a free task's spawn"
                $ \repo -> do
                    parent <- tenXAtFanOut bin repo
                    _ <- succeeded =<< taskAdded bin repo (taskFileJson (plainTask "fix" []))
                    w1 <- worktree repo "w1"
                    c1 <- childRun bin w1 parent "n1" "t1"
                    qid <- askedQid bin w1 "Confirm" ["the", "plan", "holds?"]
                    _ <-
                        succeeded
                            =<< state
                                bin
                                repo
                                [ "rule"
                                , Text.unpack qid
                                , "--answer"
                                , "confirmed"
                                , "--why"
                                , "fits t1"
                                , "--cost"
                                , "none"
                                ]
                    advice <- succeeded =<< state bin repo ["next"]
                    take 3 advice
                        `shouldBe` [ "RESUME " <> c1 <> " with the answer to " <> qid <> ": confirmed"
                                   , "SPAWN engineer --task fix background: yes"
                                   , "  at engineers: children at work - each runs on its own; do what each unindented line says, then state next"
                                   ]

            it "runs from init to done, its child through the engineer flow" $ \repo -> do
                parent <- startedIn bin repo ["--notes", repo.notes, "--flow", "10x"]
                let tasks = repo.root </> "tasks.json"
                Text.writeFile tasks (breakdownJson [(plainTask "t1" []) {fuel = Low}])
                plan <- writtenPlan repo
                for_
                    [ ["gather.enough"]
                    , ["gather/notes.done"]
                    , ["plan.done", plan]
                    , ["skip_refine.run"]
                    , ["simplify_plan.done"]
                    , ["standards_plan.done"]
                    , ["align_plan.done"]
                    , ["present.done"]
                    , ["confirm.confirmed"]
                    , ["breakdown.done", "--tasks", tasks]
                    ]
                    (succeeded <=< state bin repo . ("record" :))
                spawn <- succeeded =<< state bin repo ["next"]
                take 1 spawn `shouldBe` ["SPAWN engineer --task t1 background: yes"]
                w1 <- worktree repo "w1"
                _ <- childRun bin w1 parent "n1" "t1"
                -- The task's Fuel is the child's from init: it records none.
                child <- driveOn bin w1 (drop 1 trivialPath)
                child `shouldBe` drop 1 trivialTranscript
                merging <- succeeded =<< state bin repo ["next"]
                recorded merging `shouldBe` []
                for_
                    [["task", "t1", "merged", prUrlString], ["merge.done", prUrlString]]
                    (succeeded <=< state bin repo . ("record" :))
                done <- succeeded =<< state bin repo ["next"]
                take 1 done `shouldBe` ["DONE " <> prUrl]

            it
                "keeps a round's PR open, loops back to gather with fresh budgets, and respawns the task"
                $ \repo -> do
                    parent <- startedIn bin repo ["--notes", repo.notes, "--flow", "10x"]
                    writeFile repo.prJson (pullRequest True "OPEN")
                    let tasks = repo.root </> "tasks.json"
                        -- Balanced's five researchers, each picked, spawned and handed back.
                        fiveResearched =
                            concat
                                ( replicate
                                    5
                                    [ ["gather.research"]
                                    , ["gather/research.spawned"]
                                    , ["gather/research.handed_back"]
                                    ]
                                )
                    plan <- writtenPlan repo
                    let agreed =
                            [ ["gather.enough"]
                            , ["gather/notes.done"]
                            , ["plan.done", plan]
                            , ["skip_refine.run"]
                            , ["simplify_plan.done"]
                            , ["standards_plan.done"]
                            , ["align_plan.done"]
                            , ["present.done"]
                            , ["confirm.confirmed"]
                            , ["breakdown.done", "--tasks", tasks]
                            ]
                    Text.writeFile tasks (breakdownJson [roundTask "t1" prUrl])
                    for_ (fiveResearched <> agreed) (succeeded <=< state bin repo . ("record" :))
                    w1 <- worktree repo "w1"
                    _ <- childRun bin w1 parent "n1" "t1"
                    for_
                        [["override", "ready", "the", "test", "starts", "here"]]
                        (succeeded <=< state bin w1)
                    skipped <- succeeded =<< state bin w1 ["next"]
                    recorded skipped `shouldBe` ["ready.skipped -> out"]
                    merging <- succeeded =<< state bin repo ["next"]
                    recorded merging `shouldBe` []
                    merging
                        `shouldSatisfy` mentions
                            "state record merge.next_round - back to gather, the round loop's next round"
                    for_
                        (["merge.next_round"] : fiveResearched)
                        (succeeded <=< state bin repo . ("record" :))
                    spent <- state bin repo ["record", "gather.research"]
                    spent.code `shouldBe` 2
                    for_ agreed (succeeded <=< state bin repo . ("record" :))
                    respawn <- succeeded =<< state bin repo ["next"]
                    take 1 respawn `shouldBe` ["SPAWN engineer --task t1 background: yes"]

            it
                "runs another round on a task in review: spawns it under a fresh notes dir, refused while its child runs, kept on READY"
                $ \repo -> do
                    parent <- startedIn bin repo ["--notes", repo.notes, "--flow", "10x"]
                    writeFile repo.prJson (pullRequest True "OPEN")
                    let tasks = repo.root </> "tasks.json"
                    Text.writeFile
                        tasks
                        (breakdownJson [(plainTask "t1" []) {repo = Just (Event.Repo "o" "r")}])
                    for_
                        [ ["override", "breakdown", "the", "plan", "is", "agreed"]
                        , ["record", "breakdown.done", "--tasks", tasks]
                        ]
                        (succeeded <=< state bin repo)
                    w1 <- worktree repo "w1"
                    _ <- childRun bin w1 parent "n1" "t1"
                    for_
                        [ ["override", "ready", "the", "test", "starts", "here"]
                        , ["record", "ready.done", prUrlString]
                        ]
                        (succeeded <=< state bin w1)
                    _ <- succeeded =<< state bin w1 ["next"]
                    inReview <- succeeded =<< state bin repo ["next"]
                    recorded inReview `shouldBe` []
                    notPr <-
                        state
                            bin
                            repo
                            ["record", "task", "t1", "round", "https://example.com/o/r/pull/1"]
                    notPr.code `shouldBe` 2
                    _ <- succeeded =<< state bin repo ["record", "task", "t1", "round", prUrlString]
                    spawn <- succeeded =<< state bin repo ["next"]
                    take 1 spawn `shouldBe` ["SPAWN engineer --task t1 background: yes"]
                    brief <- succeeded =<< state bin repo ["brief", "engineer", "--task", "t1"]
                    brief
                        `shouldSatisfy` mentions ("state init --notes /tmp/engineer-o-r-t1-r1/ --parent " <> parent)
                    w2 <- worktree repo "w2"
                    _ <- childRun bin w2 parent "n2" "t1"
                    running <- state bin repo ["record", "task", "t1", "round", prUrlString]
                    running.code `shouldBe` 2
                    for_
                        [["override", "ready", "the", "test", "starts", "here"]]
                        (succeeded <=< state bin w2)
                    skipped <- succeeded =<< state bin w2 ["next"]
                    recorded skipped `shouldBe` ["ready.skipped -> out"]
                    kept <- succeeded =<< state bin repo ["next"]
                    recorded kept `shouldBe` []
                    shown <- succeeded =<< state bin repo ["show"]
                    shown `shouldSatisfy` mentions ("PR kept " <> prUrl)

        describe "a tree of runs: a 10x under a 10x, an engineer under that" $ do
            it "climbs a question to the top and writes its one answer down to every run" $ \repo -> do
                Tree {mid, midRun, grand, grandRun} <- treeOfRuns bin repo
                qid <- askedQid bin grand "Design" ["which", "store?"]
                let q = Text.unpack qid
                midAsked <- succeeded =<< state bin mid ["next"]
                _ <- succeeded =<< state bin mid ["forward", q]
                topAsked <- succeeded =<< state bin repo ["next"]
                _ <-
                    succeeded
                        =<< state
                            bin
                            repo
                            ["rule", q, "--answer", "postgres", "--why", "already used", "--cost", "none"]
                topResume <- succeeded =<< state bin repo ["next"]
                midResume <- succeeded =<< state bin mid ["next"]
                shown <-
                    traverse (succeeded <=< \run -> state bin run ["show"]) [repo, mid, grand]
                -- The grandchild's own answer, the same, is taken and changes nothing.
                _ <-
                    succeeded
                        =<< state bin grand ["answer", q, "postgres", "--by", Text.unpack midRun]
                again <- succeeded =<< state bin grand ["show"]
                qid `shouldSatisfy` ((grandRun <> ":") `Text.isPrefixOf`)
                take 1 midAsked `shouldSatisfy` mentions ("state forward " <> qid)
                take 1 topAsked `shouldSatisfy` mentions ("state rule " <> qid)
                take 1 topResume
                    `shouldBe` ["RESUME " <> midRun <> " with the answer to " <> qid <> ": postgres"]
                take 1 midResume
                    `shouldBe` ["RESUME " <> grandRun <> " with the answer to " <> qid <> ": postgres"]
                map (mentions (qid <> " Design")) shown `shouldBe` [True, True, True]
                map (mentions "postgres") shown `shouldBe` [True, True, True]
                Just again `shouldBe` lastMaybe shown

            it
                "starts the 10x child by a --flow 10x line, spawns in the foreground below the top, and climbs a grandchild's AWAIT ci to it"
                $ \repo -> do
                    Tree {mid, midSpawn, grand, grandFirst} <- treeOfRuns bin repo
                    brief <- succeeded =<< state bin repo ["brief", "10x", "--task", "t1"]
                    writeFile repo.prJson (pullRequest True "OPEN")
                    _ <-
                        succeeded
                            =<< state bin grand ["override", "simplify_plan", "the", "test", "starts", "here"]
                    grandSpawn <- succeeded =<< state bin grand ["next"]
                    _ <-
                        succeeded
                            =<< state bin grand ["override", "await_ci", "the", "test", "starts", "here"]
                    grandAwait <- succeeded =<< state bin grand ["next"]
                    midAwait <- succeeded =<< state bin mid ["next"]
                    topAwait <- succeeded =<< state bin repo ["next"]
                    lastMaybe brief `shouldSatisfy` any (" --flow 10x " `Text.isInfixOf`)
                    -- The task's Fuel is the grandchild's from init: it gathers at once, its researchers in the foreground.
                    take 1 grandFirst `shouldBe` ["RUN one option below"]
                    grandFirst
                        `shouldSatisfy` mentions "which spawns a researcher in the foreground"
                    map (take 1) [midSpawn, grandSpawn]
                        `shouldBe` [ ["SPAWN engineer --task g1 background: no"]
                                   , ["SPAWN researcher background: no"]
                                   ]
                    map (take 1) [grandAwait, midAwait]
                        `shouldBe` replicate 2 ["HANDBACK AWAIT ci " <> prUrl]
                    take 1 topAwait `shouldBe` ["AWAIT ci " <> prUrl]

        describe "brief" $ do
            it "gives a refactorer its step's task and the stop rule" $ \repo -> do
                _ <- drive bin repo []
                stopRule <- succeeded =<< state bin repo ["render", "stop-rule"]
                brief <- succeeded =<< state bin repo ["brief", "refactorer"]
                take 1 brief `shouldBe` ["## refactor"]
                brief `shouldSatisfy` (stopRule `isSuffixOf`)

            it
                "gives a fixer only the step the run is at, and a worker no command of the lead's"
                $ \repo -> do
                    _ <-
                        drive
                            bin
                            repo
                            ( atReview
                                <> [Commit, Handback "review-lead" reviewed, Record ["pick.loop", "--row", "R1"]]
                            )
                    fixer <- succeeded =<< state bin repo ["brief", "fixer"]
                    filter ("## " `Text.isPrefixOf`) fixer `shouldBe` ["## fix"]
                    for_ ["researcher", "implementer", "refactorer", "fixer"] $ \role -> do
                        brief <- succeeded =<< state bin repo ["brief", role]
                        brief
                            `shouldSatisfy` (not . any (\line -> any (`Text.isInfixOf` line) ["state record", "state brief"]))

            it "gives a review-lead the plan-wrong line, not the stop rule" $ \repo -> do
                _ <- drive bin repo []
                planWrong <- succeeded =<< state bin repo ["render", "plan-wrong"]
                stopRule <- succeeded =<< state bin repo ["render", "stop-rule"]
                brief <- succeeded =<< state bin repo ["brief", "review-lead"]
                brief `shouldSatisfy` (planWrong `isSuffixOf`)
                brief `shouldSatisfy` (not . any (`elem` stopRule))

            it "ends an engineer's brief with the line that starts its run under this one" $ \repo -> do
                run <- tenXAtFanOut bin repo
                brief <- succeeded =<< state bin repo ["brief", "engineer", "--task", "t1"]
                drop 1 (dropWhile (/= "") brief)
                    `shouldBe` ["state init --notes <dir> --parent " <> run <> " --task t1"]

            it
                "gives a run at no fan-out a brief to fill in, ending in the line that starts a child with no task"
                $ \repo -> do
                    parent <- startedIn bin repo ["--notes", repo.notes, "--flow", "chief"]
                    brief <- succeeded =<< state bin repo ["brief", "engineer"]
                    (take 3 brief, filter ("## " `Text.isPrefixOf`) brief, take 1 (reverse brief))
                        `shouldBe` ( ["Fuel: <low|balanced|max>", "Base: <branch>", "Branch: <branch>"]
                                   , ["## The user's words", "## Plan", "## Acceptance criteria"]
                                   , ["state init --notes <dir> --parent " <> parent]
                                   )

        describe "the hooks" $ do
            it "are silent in a worktree with no run" $ \repo -> do
                said <- hook hookBin repo "resume" (sessionStart repo)
                (said.code, said.out) `shouldBe` (0, [])

            it "tell a resumed session where its run stands" $ \repo -> do
                _ <- drive bin repo [Record ["fuel.set", "balanced"]]
                said <- succeeded =<< hook hookBin repo "resume" (sessionStart repo)
                said `shouldSatisfy` mentions "step: gather"

            it "record a hand-back seen twice once, appending what they recorded" $ \repo -> do
                _ <- drive bin repo (Record ["fuel.set", "balanced"] : init toImplement)
                _ <-
                    succeeded
                        =<< hook hookBin repo "bind" (spawnResult repo Null "implementer" "a1")
                before <- logLines bin repo
                first <-
                    succeeded =<< hook hookBin repo "handback" (handedBack repo "implementer")
                once <- logLines bin repo
                again <-
                    succeeded =<< hook hookBin repo "handback" (handedBack repo "implementer")
                twice <- logLines bin repo
                first `shouldSatisfy` mentions "state: recorded"
                once `shouldSatisfy` (> before)
                (again, twice) `shouldBe` ([], once)

            it "are silent off the branch the draft PR bound the run to" $ \repo -> do
                _ <- drive bin repo (Record ["fuel.set", "balanced"] : init toImplement)
                git repo ["checkout", "-q", "-b", "other"]
                said <- succeeded =<< hook hookBin repo "resume" (sessionStart repo)
                said `shouldBe` []

            it "are silent once the drafted PR is merged or closed" $ \repo -> do
                _ <- drive bin repo (Record ["fuel.set", "balanced"] : init toImplement)
                _ <-
                    succeeded
                        =<< hook hookBin repo "bind" (spawnResult repo Null "implementer" "a1")
                before <- logLines bin repo
                for_ ["MERGED", "CLOSED"] $ \over -> do
                    writeFile repo.prJson (pullRequest False over)
                    resumed <- succeeded =<< hook hookBin repo "resume" (sessionStart repo)
                    handed <-
                        succeeded =<< hook hookBin repo "handback" (handedBack repo "implementer")
                    (resumed, handed) `shouldBe` ([], [])
                after <- logLines bin repo
                after `shouldBe` before

            it
                "name the record by hand on a log of another version, as they record nothing there"
                $ \repo -> do
                    run <- startedRun bin repo
                    replaceByHand repo run 1 2
                    said <-
                        succeeded =<< hook hookBin repo "spawn" (spawned' repo Null "researcher")
                    replyField "context" said
                        `shouldSatisfy` maybe False ("state handback <role>" `Text.isInfixOf`)

            it "tell an event they do not read, as context" $ \repo -> do
                _ <- drive bin repo []
                run <- runOf bin repo
                appendByHand repo run 2 olderEvent
                said <- succeeded =<< hook hookBin repo "resume" (sessionStart repo)
                said `shouldSatisfy` mentions "seq 2, type fuel (schema_version 2)"

            it
                "records a restart of the lead's resumed session, so its lost child is sent again"
                $ \repo -> do
                    c1 <- childAtWork bin repo
                    resumed <- succeeded =<< hook hookBin repo "resume" (sessionFrom "resume" repo)
                    resumed `shouldSatisfy` mentions "restarted"
                    lost <- succeeded =<< state bin repo ["next"]
                    take 1 lost
                        `shouldBe` [ "RESUME " <> c1 <> " lost at a restart: a fresh engineer with its spawn prompt"
                                   ]

            it "records no restart at a compaction, which keeps the lead's child" $ \repo -> do
                _ <- childAtWork bin repo
                compacted <-
                    succeeded =<< hook hookBin repo "resume" (sessionFrom "compact" repo)
                compacted `shouldSatisfy` (not . mentions "restarted")

            it "records no second restart at a startup, once no child is at work" $ \repo -> do
                _ <- childAtWork bin repo
                _ <- succeeded =<< hook hookBin repo "resume" (sessionFrom "resume" repo)
                again <- succeeded =<< hook hookBin repo "resume" (sessionFrom "startup" repo)
                again `shouldSatisfy` (not . mentions "restarted")

            it "exit 2 on stdin that is no hook event" $ \repo -> do
                said <- hook hookBin repo "resume" "not json"
                said.code `shouldBe` 2

            describe "bind each agent to its run, wherever its hooks fire" $ do
                it
                    "record the main session's worker spawn and hand-back in the run its init bound it to"
                    $ \repo -> do
                        run <- initBound bin hookBin repo Null repo ["--notes", repo.notes]
                        _ <- succeeded =<< state bin repo ["record", "fuel.set", "balanced"]
                        _ <- succeeded =<< state bin repo ["record", "gather.research"]

                        said <- workerAt hookBin repo Null "w1"

                        said `shouldSatisfy` mentions ("run " <> run <> ": recorded event")
                        loggedTypes bin repo
                            `shouldReturnContaining` ["gather/research.spawned", "gather/research.handed_back"]

                it "record a 10x session's, whose run is outside the repo its hooks fire in" $ \repo -> do
                    let tenX = repo.root </> "tenx"
                    createDirectory tenX
                    git repo {work = tenX} ["init", "-q"]
                    run <-
                        initBound
                            bin
                            hookBin
                            repo
                            Null
                            repo {work = tenX}
                            ["--notes", tenX, "--flow", "10x"]
                    _ <- succeeded =<< state bin repo {work = tenX} ["record", "gather.research"]

                    said <- workerAt hookBin repo Null "w1"

                    said `shouldSatisfy` mentions ("run " <> run <> ": recorded event")
                    loggedTypes bin repo {work = tenX}
                        `shouldReturnContaining` ["gather/research.spawned", "gather/research.handed_back"]

                it
                    "record a child engineer's worker spawn in its own run, not its parent's, at depth 1"
                    $ \repo -> do
                        (engineer, w1) <- childEngineer bin hookBin repo
                        _ <- succeeded =<< state bin w1 ["record", "gather.research"]
                        before <- logLines bin repo

                        said <-
                            succeeded =<< hook hookBin repo "spawn" (spawned' repo engineer "researcher")

                        after <- logLines bin repo
                        said `shouldSatisfy` mentions "gather/research.spawned"
                        loggedTypes bin w1 `shouldReturnContaining` ["gather/research.spawned"]
                        after `shouldBe` before

                it
                    "record a depth-2 worker's hand-back made before its spawner's hook bound it, as a foreground one is"
                    $ \repo -> do
                        (engineer, w1) <- childEngineer bin hookBin repo
                        _ <- succeeded =<< state bin w1 ["record", "gather.research"]
                        _ <-
                            succeeded =<< hook hookBin repo "spawn" (spawned' repo engineer "researcher")

                        early <-
                            succeeded
                                =<< hook
                                    hookBin
                                    repo
                                    "handback"
                                    (reportedBy repo (worker "w2" "researcher") researched)
                        bound <-
                            succeeded
                                =<< hook hookBin repo "bind" (spawnResult repo engineer "researcher" "w2")

                        early `shouldBe` []
                        bound `shouldSatisfy` mentions "state: recorded"
                        loggedTypes bin w1
                            `shouldReturnContaining` ["gather/research.spawned", "gather/research.handed_back"]

                it
                    "record a depth-2 worker's hand-back made after its spawner's hook bound it, as a background one is"
                    $ \repo -> do
                        (engineer, w1) <- childEngineer bin hookBin repo
                        _ <- succeeded =<< state bin w1 ["record", "gather.research"]
                        _ <-
                            succeeded =<< hook hookBin repo "spawn" (spawned' repo engineer "researcher")

                        _ <-
                            succeeded
                                =<< hook hookBin repo "bind" (spawnResult repo engineer "researcher" "w2")
                        back <-
                            succeeded
                                =<< hook
                                    hookBin
                                    repo
                                    "handback"
                                    (reportedBy repo (worker "w2" "researcher") researched)

                        back `shouldSatisfy` mentions "state: recorded"
                        loggedTypes bin w1
                            `shouldReturnContaining` ["gather/research.spawned", "gather/research.handed_back"]

                it
                    "hold a child engineer's hand-back while its worker is at work, and hand it back once the worker returned"
                    $ \repo -> do
                        (engineer, w1) <- childEngineer bin hookBin repo
                        _ <-
                            succeeded
                                =<< state bin w1 ["override", "await_ci", "the", "test", "starts", "here"]
                        _ <-
                            succeeded
                                =<< hook hookBin repo "bind" (spawnResult repo engineer "researcher" "r1")
                        before <- logLines bin repo

                        held <- succeeded =<< state bin w1 ["next"]
                        heldUp <- logLines bin repo
                        _ <-
                            succeeded
                                =<< hook
                                    hookBin
                                    repo
                                    "handback"
                                    (reportedBy repo (worker "r1" "researcher") researched)
                        released <- succeeded =<< state bin w1 ["next"]
                        after <- logLines bin repo

                        take 1 held `shouldBe` ["AWAIT worker researcher r1"]
                        held
                            `shouldSatisfy` mentions
                                "state handback: researcher r1 is still at work - its hand-back is not recorded"
                        heldUp `shouldBe` before
                        take 1 released `shouldSatisfy` mentions "HANDBACK AWAIT ci"
                        after `shouldSatisfy` (> before)

                it
                    "record a child engineer's own hand-back in its parent's log by its state call, its hand-back hook adding nothing"
                    $ \repo -> do
                        (engineer, w1) <- childEngineer bin hookBin repo

                        _ <- succeeded =<< state bin w1 ["stop", "failed", "no", "access"]
                        once <- logLines bin repo
                        hooked <-
                            succeeded
                                =<< hook hookBin repo "handback" (reportedBy repo engineer "FAILED no access\n")
                        after <- logLines bin repo

                        loggedTypes bin repo `shouldReturnContaining` ["handed_back"]
                        (hooked, after) `shouldBe` ([], once)

            describe "route each agent's state calls to its run" $ do
                it
                    "deny a child engineer's state call from its parent's checkout, naming the cd to its own worktree"
                    $ \repo -> do
                        (engineer, w1) <- childEngineer bin hookBin repo
                        top <- Text.strip . Text.pack <$> gitOut w1 ["rev-parse", "--show-toplevel"]

                        said <-
                            succeeded =<< hook hookBin repo "route" (ranIn repo engineer "state next")

                        replyField "decision" said `shouldBe` Just "deny"
                        replyField "reason" said
                            `shouldSatisfy` maybe False (("fix: cd " <> top <> " && state next\n") `Text.isSuffixOf`)

                it "let a child engineer's state call run once it cds to its own worktree" $ \repo -> do
                    (engineer, w1) <- childEngineer bin hookBin repo

                    said <-
                        succeeded
                            =<< hook
                                hookBin
                                repo
                                "route"
                                (ranIn repo engineer ("cd " <> Text.pack w1.work <> " && state next"))

                    said `shouldBe` []

                it "let an agent bound to no run call state anywhere" $ \repo -> do
                    _ <- drive bin repo []

                    said <-
                        succeeded
                            =<< hook hookBin repo "route" (ranIn repo (worker "e9" "engineer") "state next")

                    said `shouldBe` []

            describe "hold a lead's writes until its run starts" $ do
                it "deny a typed /engineer's edit before its state init, naming the init" $ \repo -> do
                    _ <- succeeded =<< hook hookBin repo "begin" (typed repo "engineer")

                    said <- succeeded =<< hook hookBin repo "route" (edited repo Null)

                    replyField "decision" said `shouldBe` Just "deny"
                    replyField "reason" said
                        `shouldSatisfy` maybe
                            False
                            ( "fix: state init --notes /tmp/engineer-<owner>-<repo>-<slug>/\n"
                                `Text.isSuffixOf`
                            )

                it
                    "deny a typed /10x-engineer's commit before its state init, naming the 10x's init"
                    $ \repo -> do
                        _ <- succeeded =<< hook hookBin repo "begin" (typed repo "10x-engineer")

                        said <-
                            succeeded =<< hook hookBin repo "route" (ranIn repo Null "git commit -m x")

                        replyField "decision" said `shouldBe` Just "deny"
                        replyField "reason" said
                            `shouldSatisfy` maybe False ("fix: state init --notes \"$PWD\" --flow 10x" `Text.isInfixOf`)

                it "let a typed /engineer edit and commit once its state init bound it" $ \repo -> do
                    _ <- succeeded =<< hook hookBin repo "begin" (typed repo "engineer")
                    _ <- initBound bin hookBin repo Null repo ["--notes", repo.notes]

                    said <-
                        traverse
                            (succeeded <=< hook hookBin repo "route")
                            [edited repo Null, ranIn repo Null "git add . && git commit -m x"]

                    said `shouldBe` [[], []]

                it "deny an unbound spawned engineer's push, pointing at its prompt's init line" $ \repo -> do
                    said <-
                        succeeded
                            =<< hook
                                hookBin
                                repo
                                "route"
                                (ranIn repo (worker "e9" "engineer") "git push -u origin HEAD")

                    replyField "decision" said `shouldBe` Just "deny"
                    replyField "reason" said
                        `shouldSatisfy` maybe
                            False
                            ("fix: run the `state init` line in your prompt, as written\n" `Text.isSuffixOf`)

                it
                    "deny a subagent's state init that would start a user's run, naming --parent, then --child with no parent run"
                    $ \repo -> do
                        said <-
                            succeeded
                                =<< hook
                                    hookBin
                                    repo
                                    "route"
                                    ( ranIn
                                        repo
                                        (worker "e9" "engineer")
                                        ("state init --notes " <> Text.pack repo.notes)
                                    )

                        replyField "decision" said `shouldBe` Just "deny"
                        replyField "reason" said
                            `shouldSatisfy` maybe
                                False
                                ( "fix: rerun it with --parent <run> from your brief, plus --task <id> under a fan-out; with no parent run, with --child\n"
                                    `Text.isSuffixOf`
                                )

                it
                    "let a subagent init with --child or --parent, and a top-level session with neither"
                    $ \repo -> do
                        let notes = "state init --notes " <> Text.pack repo.notes
                        said <-
                            traverse
                                (succeeded <=< hook hookBin repo "route")
                                [ ranIn repo (worker "e9" "engineer") (notes <> " --child")
                                , ranIn repo (worker "e9" "engineer") (notes <> " --parent r1 --task t1")
                                , ranIn repo Null notes
                                ]

                        said `shouldBe` [[], [], []]

                it "never gate a plain session or an implementer" $ \repo -> do
                    said <-
                        traverse
                            (succeeded <=< hook hookBin repo "route")
                            [ edited repo Null
                            , ranIn repo Null "git commit -m x"
                            , edited repo (worker "i1" "implementer")
                            ]

                    said `shouldBe` [[], [], []]

            describe "tell how work begins" $ do
                it "tell a spawned engineer its run starts at its prompt's init line" $ \repo -> do
                    said <-
                        succeeded
                            =<< hook hookBin repo "begin" (agentStarted repo (worker "e1" "engineer"))

                    replyField "context" said
                        `shouldSatisfy` maybe False ("the `state init` line" `Text.isInfixOf`)

                it "give a spawned implementer what state brief implementer gives" $ \repo -> do
                    _ <- drive bin repo []
                    brief <- succeeded =<< state bin repo ["brief", "implementer"]

                    said <-
                        succeeded
                            =<< hook hookBin repo "begin" (agentStarted repo (worker "i1" "implementer"))

                    replyField "context" said `shouldBe` Just (Text.unlines brief)

                it "tell a typed /engineer it begins with state" $ \repo -> do
                    said <- succeeded =<< hook hookBin repo "begin" (typed repo "engineer")

                    replyField "context" said
                        `shouldSatisfy` maybe False ("`state init ...`" `Text.isInfixOf`)

-- | One call of the binary: its exit code and its output, line by line.
data Ran = Ran {code :: Int, out :: [Text], err :: [Text]}

state :: FilePath -> Repo -> [String] -> IO Ran
state bin repo = stateIn bin repo ""

{- | Every call's store is a throwaway temp one, so it skips the fsyncs that
would cost each call ~4ms.
-}
stateIn :: FilePath -> Repo -> String -> [String] -> IO Ran
stateIn bin repo stdin argv = do
    (exit, out, err) <-
        readCreateProcessWithExitCode
            (proc bin ("--store-durability" : "unsynced" : argv))
                { cwd = Just repo.work
                , env = Just repo.env
                }
            stdin
    let code = case exit of
            ExitSuccess -> 0
            ExitFailure n -> n
    pure (Ran code (Text.lines (Text.pack out)) (Text.lines (Text.pack err)))

-- | One @state-hook <name>@ call, fed the hook event on stdin.
hook :: FilePath -> Repo -> String -> String -> IO Ran
hook bin repo name stdin = stateIn bin repo stdin [name]

sessionStart :: Repo -> String
sessionStart = sessionFrom "startup"

-- | The lead's session starting for this reason: startup, resume or compact.
sessionFrom :: Text -> Repo -> String
sessionFrom source repo =
    hookEvent
        repo
        Null
        [ "event" .= String "sessionStart"
        , "source" .= String source
        , "harness" .= String "claude-code"
        , "transcript_path" .= String "/home/u/.claude/projects/p/s1.jsonl"
        , "request_model" .= Null
        ]

-- | A subagent of this role hands back @READY@.
handedBack :: Repo -> Text -> String
handedBack repo role = reportedBack repo role (ready "")

-- | A subagent of this role hands back this message.
reportedBack :: Repo -> Text -> Text -> String
reportedBack repo role = reportedBy repo (worker "a1" role)

-- | This subagent hands back this message, its hook firing in the repo's worktree.
reportedBy :: Repo -> Value -> Text -> String
reportedBy repo agent message =
    hookEvent
        repo
        agent
        [ "event" .= String "beforeTool"
        , "tool" .= String "handback"
        , "input" .= object ["message" .= String message]
        , "history" .= ([] :: [Text])
        ]

-- | A subagent, by its id and role, as the hook payload names it.
worker :: Text -> Text -> Value
worker agentId role = object ["id" .= agentId, "role" .= role]

-- | The lead spawns a subagent of this role.
spawned :: Repo -> Text -> String
spawned repo = spawned' repo Null

-- | This agent (the lead: @Null@) spawns a subagent of this role.
spawned' :: Repo -> Value -> Text -> String
spawned' repo agent role =
    hookEvent
        repo
        agent
        [ "event" .= String "beforeTool"
        , "tool" .= String "delegate"
        , "input" .= object ["subagent_type" .= role]
        , "history" .= ([] :: [Text])
        ]

{- | This agent's spawn of a subagent of this role done, its result naming the
subagent's id: a PostToolUse on Agent (contract/fixtures/live-run.json).
-}
spawnResult :: Repo -> Value -> Text -> Text -> String
spawnResult repo agent role child =
    hookEvent
        repo
        agent
        [ "event" .= String "afterTool"
        , "tool" .= String "delegate"
        , "input"
            .= object
                [ "description" .= String "a worker"
                , "prompt" .= String "state brief"
                , "subagent_type" .= role
                , "run_in_background" .= False
                ]
        , "output"
            .= object ["status" .= String "completed", "agentId" .= child, "agentType" .= role]
        , "context" .= Null
        ]

{- | @cd <dir> && state init <args>@, run in @dir@ by this agent, whose hooks
fire in @at@'s worktree; then its PostToolUse on Bash binds it. The run's id.
-}
initBound ::
    FilePath -> FilePath -> Repo -> Value -> Repo -> [String] -> IO Text
initBound bin hookBin at agent dir argv = do
    printed <- succeeded =<< state bin dir ("init" : argv)
    let command = "cd " <> dir.work <> " && state init " <> unwords argv
    _ <- succeeded =<< hook hookBin at "bind" (ranShell at agent command printed)
    case printed of
        [line, _, "next: state next"] | Just run <- Text.stripPrefix "started " line -> pure run
        other -> fail ("not started: " <> show other)

-- | This agent's shell command done, printing these lines: a PostToolUse on Bash.
ranShell :: Repo -> Value -> String -> [Text] -> String
ranShell repo agent command printed =
    hookEvent
        repo
        agent
        [ "event" .= String "afterTool"
        , "tool" .= String "shell"
        , "input"
            .= object ["command" .= command, "description" .= String "start the run"]
        , "output"
            .= object
                [ "stdout" .= Text.unlines printed
                , "stderr" .= String ""
                , "interrupted" .= False
                ]
        , "context" .= Null
        ]

{- | This agent spawns a researcher @w@, bound by the spawn's PostToolUse, which
hands back its report; every hook fires in the repo's worktree. What the
hand-back's hook replied.
-}
workerAt :: FilePath -> Repo -> Value -> Text -> IO [Text]
workerAt hookBin repo agent w = do
    _ <- succeeded =<< hook hookBin repo "spawn" (spawned' repo agent "researcher")
    _ <-
        succeeded =<< hook hookBin repo "bind" (spawnResult repo agent "researcher" w)
    succeeded
        =<< hook
            hookBin
            repo
            "handback"
            (reportedBy repo (worker w "researcher") researched)

{- | A 10x run at its fan-out in the repo's worktree, and the engineer @e1@ it
spawned for task @t1@, whose hooks fire in the 10x's worktree: it ran its
brief's @cd <w1> && state init ...@ there, its notes in @n1@. The engineer,
and its worktree @w1@.
-}
childEngineer :: FilePath -> FilePath -> Repo -> IO (Value, Repo)
childEngineer bin hookBin repo = do
    parent <- tenXAtFanOut bin repo
    -- Inside the parent's checkout, as Claude Code puts a worktree: a path prefix of none.
    w1 <- worktreeAt repo (repo.work </> ".claude" </> "worktrees" </> "w1") "w1"
    let engineer = worker "e1" "engineer"
    _ <-
        initBound
            bin
            hookBin
            repo
            engineer
            w1
            ["--notes", repo.root </> "n1", "--parent", Text.unpack parent, "--task", "t1"]
    pure (engineer, w1)

-- | The event types the worktree's run holds.
loggedTypes :: FilePath -> Repo -> IO [Text]
loggedTypes bin repo =
    (\rows -> [kind | Just (String kind) <- map (column "type") rows])
        <$> dumped bin repo

-- | A column of a row as @state dump@ prints it.
column :: Text -> Text -> Maybe Value
column key row =
    Aeson.decodeStrictText row >>= \case
        Object columns -> KeyMap.lookup (Key.fromText key) columns
        _ -> Nothing

-- | The worktree's run's rows as @state dump@ prints them, one JSON object a line.
dumped :: FilePath -> Repo -> IO [Text]
dumped bin repo = runOf bin repo >>= dumpOf bin repo

-- | A run's rows as @state dump@ prints them.
dumpOf :: FilePath -> Repo -> Text -> IO [Text]
dumpOf bin repo run = succeeded =<< state bin repo ["dump", Text.unpack run]

-- | The worktree's run's id, as @state show@ names it.
runOf :: FilePath -> Repo -> IO Text
runOf bin repo =
    (succeeded =<< state bin repo ["show"]) >>= \case
        shown : _
            | Just named <- Text.stripPrefix "run: " shown ->
                pure (Text.takeWhile (/= ' ') named)
        other -> fail ("no run shown: " <> show other)

{- | The run store's file: the environment's @XDG_STATE_HOME@ is the repo's
own, never the user's.
-}
storeOf :: Repo -> FilePath
storeOf repo = repo.root </> ".local" </> "state" </> "state" </> "kernel-v2.db"

-- | An event row written by hand, at this seq, as another kernel would write it.
appendByHand :: Repo -> Text -> Int -> OlderEvent -> IO ()
appendByHand repo run n (OlderEvent version kind payload) = SQLite.withConnection (storeOf repo) $ \c ->
    SQLite.execute
        c
        "INSERT INTO events (run_id, seq, schema_version, type, time, data) VALUES (?, ?, ?, ?, ?, ?)"
        (run, n, version, kind, "2025-11-21T00:00:00.000Z" :: Text, payload)

{- | An event row's payload version rewritten by hand, at this seq, as
another kernel's store would hold it: its append-only trigger dropped first.
-}
replaceByHand :: Repo -> Text -> Int -> Int -> IO ()
replaceByHand repo run n version = SQLite.withConnection (storeOf repo) $ \c -> do
    SQLite.execute_ c "DROP TRIGGER events_no_update"
    SQLite.execute
        c
        "UPDATE events SET schema_version = ? WHERE run_id = ? AND seq = ?"
        (version, run, n)

-- | The run's rows as stored, every column but SQLite's position.
storedRows ::
    Repo ->
    Text ->
    IO [(Int, Int, Text, Text, Maybe Text, Maybe Text, Maybe Text, Text)]
storedRows repo run = SQLite.withConnection (storeOf repo) $ \c ->
    SQLite.query
        c
        "SELECT seq, schema_version, type, time, session_id, head_sha, hook_digest, data FROM events WHERE run_id = ? ORDER BY seq"
        (SQLite.Only run)

-- | An event row's payload version, type and data.
data OlderEvent = OlderEvent Int Text Text

-- | An event of payload version 2, which this kernel does not read.
olderEvent :: OlderEvent
olderEvent = OlderEvent 2 "fuel" "{}"

-- | Each expected entry is in the list.
shouldReturnContaining :: IO [Text] -> [Text] -> IO ()
shouldReturnContaining act expected = act >>= \got -> for_ expected (\e -> got `shouldContain` [e])

-- | This agent's shell command about to run, its hook firing in the repo's worktree.
ranIn :: Repo -> Value -> Text -> String
ranIn repo agent command =
    hookEvent
        repo
        agent
        [ "event" .= String "beforeTool"
        , "tool" .= String "shell"
        , "input" .= object ["command" .= command]
        , "history" .= ([] :: [Text])
        ]

-- | The lead typing @/<skill>@.
typed :: Repo -> Text -> String
typed repo skill = hookEvent repo Null ["event" .= String "promptExpansion", "skill" .= skill]

-- | This agent (the lead: @Null@) about to edit a file.
edited :: Repo -> Value -> String
edited repo agent =
    hookEvent
        repo
        agent
        [ "event" .= String "beforeTool"
        , "tool" .= String "edit"
        , "input" .= object ["file_path" .= String "README.md"]
        , "history" .= ([] :: [Text])
        ]

-- | This subagent starting, its hook firing in the repo's worktree.
agentStarted :: Repo -> Value -> String
agentStarted repo agent = hookEvent repo agent ["event" .= String "agentStart"]

-- | A text field of the reply a hook printed.
replyField :: Aeson.Key -> [Text] -> Maybe Text
replyField key said = case Aeson.decodeStrictText (Text.concat said) of
    Just (Object fields) | Just (String value) <- KeyMap.lookup key fields -> Just value
    _ -> Nothing

-- | The neutral hook event of the lead's (a @Null@ agent) or a subagent's session in the worktree.
hookEvent :: Repo -> Value -> [Pair] -> String
hookEvent repo agent fields =
    LBS8.unpack
        ( encode
            ( object
                (["session" .= String "s1", "cwd" .= repo.work, "agent" .= agent] <> fields)
            )
        )

mentions :: Text -> [Text] -> Bool
mentions needle = any (needle `Text.isInfixOf`)

logLines :: FilePath -> Repo -> IO Int
logLines bin repo = length <$> dumped bin repo

-- | The output of a call that must succeed.
succeeded :: Ran -> IO [Text]
succeeded ran
    | ran.code == 0 = pure ran.out
    | otherwise =
        []
            <$ expectationFailure
                ("exit " <> show ran.code <> ": " <> Text.unpack (Text.unlines ran.err))

-- | @init@ in the worktree's notes; the run's id.
startedRun :: FilePath -> Repo -> IO Text
startedRun bin repo = startedIn bin repo ["--notes", repo.notes]

-- | @init@ with these arguments; the run's id.
startedIn :: FilePath -> Repo -> [String] -> IO Text
startedIn bin repo argv =
    (succeeded =<< state bin repo ("init" : argv)) >>= \case
        [line, _, "next: state next"] | Just run <- Text.stripPrefix "started " line -> pure run
        other -> fail ("not started: " <> show other)

{- | A 10x run at its fan-out with tasks @t1@ and @t2@, @t2@ depending on
@t1@; the run's id.
-}
tenXAtFanOut :: FilePath -> Repo -> IO Text
tenXAtFanOut bin repo = do
    run <- startedIn bin repo ["--notes", repo.notes, "--flow", "10x"]
    let tasks = repo.root </> "tasks.json"
    Text.writeFile tasks (breakdownJson [plainTask "t1" [], plainTask "t2" ["t1"]])
    for_
        [ ["override", "breakdown", "the", "plan", "is", "agreed"]
        , ["record", "breakdown.done", "--tasks", tasks]
        ]
        (succeeded <=< state bin repo)
    pure run

-- | The child run a parent's brief starts for this task, its notes in @dir@ under the repo's root; its id.
childRun :: FilePath -> Repo -> Text -> FilePath -> Text -> IO Text
childRun bin repo parent dir task =
    startedIn
        bin
        repo
        [ "--notes"
        , repo.root </> dir
        , "--parent"
        , Text.unpack parent
        , "--task"
        , Text.unpack task
        ]

-- | A direct child of a parent at no fan-out, its notes in @dir@ under the repo's root; its id.
directChild :: FilePath -> Repo -> Text -> FilePath -> IO Text
directChild bin repo parent dir =
    startedIn
        bin
        repo
        ["--notes", repo.root </> dir, "--parent", Text.unpack parent]

-- | A 10x run at its fan-out with task t1's child started in its own worktree; the child's run id.
childAtWork :: FilePath -> Repo -> IO Text
childAtWork bin repo = do
    parent <- tenXAtFanOut bin repo
    w1 <- worktree repo "w1"
    childRun bin w1 parent "n1" "t1"

-- | A child run of a 10x fan-out in its own worktree, asking a Pick; that worktree and the question's id.
childQuestion :: FilePath -> Repo -> IO (Repo, Text)
childQuestion bin repo = do
    parent <- tenXAtFanOut bin repo
    w1 <- worktree repo "w1"
    _ <- childRun bin w1 parent "n1" "t1"
    (w1,) <$> askedQid bin w1 "Pick" ["which", "lib?"]

{- | Three runs, each in its own worktree and notes: the top 10x at its
fan-out, a 10x child on its task t1, at its own fan-out, and an engineer
grandchild on the child's task g1. Each child starts by its parent's brief
line.
-}
data Tree = Tree
    { top :: Text
    , mid :: Repo
    , midRun :: Text
    , midSpawn :: [Text]
    , grand :: Repo
    , grandRun :: Text
    , grandFirst :: [Text]
    }

treeOfRuns :: FilePath -> Repo -> IO Tree
treeOfRuns bin repo = do
    top <- startedIn bin repo ["--notes", repo.notes, "--flow", "10x"]
    _ <- brokenDown bin repo [(plainTask "t1" []) {flow = TenXFlow}]
    w1 <- worktree repo "w1"
    let mid = w1 {notes = repo.root </> "n1"}
    midRun <- briefedRun bin repo "10x" "t1" mid
    midSpawn <- brokenDown bin mid [plainTask "g1" []]
    w2 <- worktree repo "w2"
    let grand = w2 {notes = repo.root </> "n2"}
    grandRun <- briefedRun bin mid "engineer" "g1" grand
    grandFirst <- succeeded =<< state bin grand ["next"]
    pure Tree {top, mid, midRun, midSpawn, grand, grandRun, grandFirst}

-- | A 10x run's breakdown of these tasks, agreed and recorded; the @next@ after it.
brokenDown :: FilePath -> Repo -> [Task] -> IO [Text]
brokenDown bin repo tasks = do
    let file = repo.notes </> "tasks.json"
    Text.writeFile file (breakdownJson tasks)
    for_
        [ ["override", "breakdown", "the", "plan", "is", "agreed"]
        , ["record", "breakdown.done", "--tasks", file]
        ]
        (succeeded <=< state bin repo)
    succeeded =<< state bin repo ["next"]

-- | The child run the parent's brief for this role and task starts in the child's notes, by the brief's init line; its id.
briefedRun :: FilePath -> Repo -> String -> String -> Repo -> IO Text
briefedRun bin parent role task child = do
    brief <- succeeded =<< state bin parent ["brief", role, "--task", task]
    case map Text.unpack . Text.words <$> lastMaybe brief of
        Just ("state" : "init" : flags) ->
            startedIn
                bin
                child
                [if flag == "<dir>" then child.notes else flag | flag <- flags]
        other -> fail ("no init line: " <> show other)

lastMaybe :: [a] -> Maybe a
lastMaybe = foldl (\_ line -> Just line) Nothing

-- | @state ask --kind <kind> <question>@; the id it prints.
askedQid :: FilePath -> Repo -> String -> [String] -> IO Text
askedQid bin repo kind question = do
    asked : _ <- succeeded =<< state bin repo (["ask", "--kind", kind] <> question)
    pure (Text.drop (Text.length "asked ") asked)

-- | The plan the lead writes to the notes dir; its path.
writtenPlan :: Repo -> IO FilePath
writtenPlan repo = plan <$ writeFile plan "the plan"
  where
    plan = repo.notes </> "plan.md"

-- | @state record task add@ on a task file holding these contents.
taskAdded :: FilePath -> Repo -> Text -> IO Ran
taskAdded bin repo contents = do
    let file = repo.root </> "task.json"
    Text.writeFile file contents
    state bin repo ["record", "task", "add", file]

-- | A worktree of its own on a new branch, as a child runs in; the repo as seen from it.
worktree :: Repo -> String -> IO Repo
worktree repo name = worktreeAt repo (repo.root </> name) name

-- | A worktree at this path, on a new branch of this name.
worktreeAt :: Repo -> FilePath -> String -> IO Repo
worktreeAt repo path name = do
    git repo ["worktree", "add", "-q", "-b", name, path]
    pure repo {work = path}

-- | Records in the parent a hand-back a child made by hand, not by its state, as the 10x pipes it in.
relay :: FilePath -> Repo -> [Text] -> IO ()
relay bin parent output = case dropWhile (not . ("HANDBACK " `Text.isPrefixOf`)) output of
    handback : run : _
        | Just report <- Text.stripPrefix "HANDBACK " handback ->
            void
                ( succeeded
                    =<< stateIn
                        bin
                        parent
                        (Text.unpack (Text.unlines [report, run]))
                        ["handback", "engineer"]
                )
    _ -> expectationFailure ("no hand-back in " <> show output)

-- | What a scenario does between two @state next@ calls.
data Act
    = Record [String]
    | -- | A role's hand-back on stdin, given the worktree's HEAD.
      Handback String (Text -> Text)
    | -- | A commit of one changed line.
      Commit
    | -- | The draft PR the scripted @gh@ reports from now on: @next@ records @draft.done@ from it.
      OpenPr
    | Override String
    | -- | The lead spawns a subagent of this role, as the spawn hook sees it.
      Spawn Text
    | -- | A subagent of this role hands back this message, as the hand-back hook sees it.
      HandsBack Text Text
    | -- | The lead asks the user a question of this kind, and the user answers it.
      AskUser String [String]
    | -- | The lead writes its plan to the notes dir and records @plan.done@.
      Planned

{- | Starts the run, then each act and a @state next@ after it, every call
exiting 0. The @recorded@ lines they print, without their sequence numbers:
the run's path, the steps @next@ records itself included.
-}
drive :: FilePath -> Repo -> [Act] -> IO [Text]
drive bin repo acts = startedRun bin repo *> driveOn bin repo acts

-- | 'drive' on a run started already, such as a child its parent's brief started.
driveOn :: FilePath -> Repo -> [Act] -> IO [Text]
driveOn bin repo acts = do
    first <- next
    rest <- traverse (\act -> (<>) <$> perform act <*> next) acts
    pure (recorded (concat (first : rest)))
  where
    next = succeeded =<< state bin repo ["next"]
    perform = \case
        Record argv -> succeeded =<< state bin repo ("record" : argv)
        Handback role report -> do
            sha <- Text.strip . Text.pack <$> gitOut repo ["rev-parse", "HEAD"]
            succeeded =<< stateIn bin repo (Text.unpack (report sha)) ["handback", role]
        Commit -> [] <$ commitLine repo
        OpenPr -> [] <$ writeFile repo.prJson (pullRequest True "OPEN")
        Override to ->
            succeeded =<< state bin repo ["override", to, "the", "test", "starts", "here"]
        -- The spawn's PreToolUse, then its PostToolUse, which binds the worker.
        Spawn role ->
            (<>)
                <$> hooked "spawn" (spawned repo role)
                <*> hooked "bind" (spawnResult repo Null role "a1")
        HandsBack role message -> hooked "handback" (reportedBack repo role message)
        AskUser kind question -> do
            asked <- succeeded =<< state bin repo (["ask", "--kind", kind] <> question)
            case concatMap Text.words (take 1 asked) of
                ["asked", qid] -> succeeded =<< state bin repo ["answer", Text.unpack qid, "yes"]
                _ -> [] <$ expectationFailure ("no question asked: " <> show asked)
        Planned -> do
            path <- writtenPlan repo
            succeeded =<< state bin repo ["record", "plan.done", path]
    -- The context a hook replies with, line by line, as the CLI prints it.
    hooked name event = do
        hookBin <- getEnv "STATE_HOOK_BIN"
        said <- succeeded =<< hook hookBin repo name event
        pure (concatMap contextLines said)
    contextLines reply =
        maybe
            []
            (map (unstated . aboutNoRun) . Text.lines)
            (replyField "context" [reply])

unstated :: Text -> Text
unstated line = fromMaybe line (Text.stripPrefix "state: " line)

-- | A hook's line without the run it names, @run <id>: @.
aboutNoRun :: Text -> Text
aboutNoRun line = case Text.stripPrefix "run " line of
    Just rest
        | (_, after) <- Text.breakOn ": " rest
        , not (Text.null after) ->
            Text.drop 2 after
    _ -> line

{- | The @recorded <seq> <event> -> <state>@ lines of an output, and a hook's
@recorded event <seq> ...@ of a child's spawn or hand-back, without their
sequence numbers.
-}
recorded :: [Text] -> [Text]
recorded = concatMap $ \line -> case Text.words line of
    ["recorded", _, event, "->", at] -> [event <> " -> " <> at]
    ["recorded", "event", _, event, "->", at] -> [event <> " -> " <> at]
    _ -> []

-- | A researcher's report as its skill shapes it: no token on line 1.
researched :: Text
researched = "The Index, ranked\n1. src/State.hs:12 - the fold\n"

ready, reviewed, simplified :: Text -> Text
ready _ = "READY\nDone.\n"
reviewed sha = "| # | Finding |\n|---|---|\nReviewed head: " <> sha <> "\n"
simplified sha = "READY\nSimplified: " <> sha <> "\n"

-- | From the start to the draft PR and a first commit on it.
toImplement :: [Act]
toImplement =
    [ Record ["gather.research"]
    , Spawn "researcher"
    , Record ["gather.interview"]
    , AskUser "Scope" ["which", "scope?"]
    , Record ["interview.asked"]
    , HandsBack "researcher" researched
    ]
        <> gathered
        <> [Planned]
        <> refinePasses
        <> [ Record ["confirm.confirmed"]
           , OpenPr
           , Commit
           , Handback "implementer" ready
           ]

-- | Each refine pass hands back, then the lead presents the plan: from @plan@'s done to @confirm@.
refinePasses :: [Act]
refinePasses =
    [ Handback "researcher" ready
    , Handback "researcher" ready
    , Handback "reviewer" ready
    , Record ["present.done"]
    ]

-- | The gather ended with no researcher open: its await goes on by itself to the notes.
gathered :: [Act]
gathered = [Record ["gather.enough"], Record ["gather/notes.done"]]

-- | A Balanced run to its first Simplify of the PR.
toSimplifyPr :: [Act]
toSimplifyPr =
    Record ["fuel.set", "balanced"]
        : toImplement
            <> [ Handback "review-lead" reviewed
               , Record ["pick.final"]
               , Handback "fixer" ready
               , Handback "fixer" ready
               ]

balancedPath :: [Act]
balancedPath =
    toSimplifyPr
        <> [ Handback "fixer" simplified
           , Record ["await_ci.green"]
           , Record ["ready.done", prUrlString]
           ]

balancedTranscript :: [Text]
balancedTranscript =
    [ "fuel.set -> gather"
    , "gather.research -> gather/research"
    , "gather/research.spawned -> gather"
    , "gather.interview -> interview"
    , "interview.asked -> gather"
    , "gather/research.handed_back -> gather"
    , "worker_returned -> gather"
    , "gather.enough -> gather/notes"
    , "gather/notes.done -> plan"
    ]
        <> refinedTranscript
        <> [ "confirm.confirmed -> draft"
           , "draft.done -> implement"
           , "implement.done -> skip_refactor"
           , "skip_refactor.skip -> review"
           , "review.rows -> pick"
           , "pick.final -> describe"
           , "describe.done -> visual"
           , "visual.done -> simplify_pr"
           , "simplify_pr.done -> await_ci"
           , "await_ci.green -> ready"
           , "ready.done -> out"
           ]

-- | Balanced, its review clean: no pick and no fix loop.
cleanPath :: [Act]
cleanPath =
    Record ["fuel.set", "balanced"]
        : toImplement
            <> [ Record ["review.clean"]
               , Handback "fixer" ready
               , Handback "fixer" ready
               , Handback "fixer" simplified
               , Record ["await_ci.green"]
               , Record ["ready.done", prUrlString]
               ]

cleanTranscript :: [Text]
cleanTranscript =
    [ "fuel.set -> gather"
    , "gather.research -> gather/research"
    , "gather/research.spawned -> gather"
    , "gather.interview -> interview"
    , "interview.asked -> gather"
    , "gather/research.handed_back -> gather"
    , "worker_returned -> gather"
    , "gather.enough -> gather/notes"
    , "gather/notes.done -> plan"
    ]
        <> refinedTranscript
        <> [ "confirm.confirmed -> draft"
           , "draft.done -> implement"
           , "implement.done -> skip_refactor"
           , "skip_refactor.skip -> review"
           , "review.clean -> describe"
           , "describe.done -> visual"
           , "visual.done -> simplify_pr"
           , "simplify_pr.done -> await_ci"
           , "await_ci.green -> ready"
           , "ready.done -> out"
           ]

-- | Low, a trivial task: the agent gathers nothing, skips the proposal and the refactor, so no hand-back of theirs.
trivialPath :: [Act]
trivialPath =
    Record ["fuel.set", "low"]
        : gathered
            <> [ Planned
               , Record ["skip_refine.skip"]
               , Record ["present.done"]
               , Record ["confirm.confirmed"]
               , OpenPr
               , Commit
               , Handback "implementer" ready
               , Record ["skip_refactor.skip"]
               , Handback "review-lead" reviewed
               , Record ["pick.final"]
               , Handback "fixer" ready
               , Handback "fixer" ready
               , Handback "fixer" simplified
               , Record ["await_ci.green"]
               , Record ["ready.done", prUrlString]
               ]

trivialTranscript :: [Text]
trivialTranscript =
    [ "fuel.set -> gather"
    , "gather.enough -> gather/notes"
    , "gather/notes.done -> plan"
    , "artifact -> plan"
    , "plan.done -> skip_refine"
    , "skip_refine.skip -> present"
    , "present.done -> confirm"
    , "confirm.confirmed -> draft"
    , "draft.done -> implement"
    , "implement.done -> skip_refactor"
    , "skip_refactor.skip -> review"
    , "review.rows -> pick"
    , "pick.final -> describe"
    , "describe.done -> visual"
    , "visual.done -> simplify_pr"
    , "simplify_pr.done -> await_ci"
    , "await_ci.green -> ready"
    , "ready.done -> out"
    ]

{- | 'trivialPath' from the gather, in a chief's request on a targeted PR:
the plan is neither refined, presented nor confirmed, no draft PR opened, as GitHub
has the target's, and no ready, which the request skips.
-}
targetedPath :: [Act]
targetedPath = take 3 (drop 1 trivialPath) <> drop 9 (init trivialPath)

targetedTranscript :: [Text]
targetedTranscript =
    [ "engineer/gather.enough -> engineer/gather/notes"
    , "engineer/gather/notes.done -> engineer/plan"
    , "artifact -> engineer/plan"
    , "engineer/plan.done -> engineer/skip_refine"
    , "engineer/skip_refine.skip -> engineer/present"
    , "engineer/present.done -> engineer/confirm"
    , "engineer/confirm.confirmed -> engineer/draft"
    , "engineer/draft.done -> engineer/implement"
    , "engineer/implement.done -> engineer/skip_refactor"
    , "engineer/skip_refactor.skip -> engineer/review"
    , "engineer/review.rows -> engineer/pick"
    , "engineer/pick.final -> engineer/describe"
    , "engineer/describe.done -> engineer/visual"
    , "engineer/visual.done -> engineer/simplify_pr"
    , "engineer/simplify_pr.done -> engineer/await_ci"
    , "engineer/await_ci.green -> engineer/ready"
    , "engineer/ready.skipped -> next"
    ]

{- | 'trivialPath' as a round on 'roundUrlString': no draft PR opened, as
GitHub has the round's, and no ready, which the round skips.
-}
roundPath :: [Act]
roundPath = take 7 trivialPath <> drop 8 (init trivialPath)

-- | The PR a user's round names, which the scripted @gh@ reports by URL alone.
roundUrlString :: String
roundUrlString = "https://github.com/o/r/pull/7"

-- | Balanced, moved to the review by override.
atReview :: [Act]
atReview = [Record ["fuel.set", "balanced"], Override "review"]

-- | A review back with its rows, and the lead's picks: a loop on this row.
reviewRound :: String -> [String] -> [Act]
reviewRound label verdicts =
    [ Commit
    , Handback "review-lead" reviewed
    , Record (["pick.loop", "--row", label] <> verdicts)
    ]

prUrl :: Text
prUrl = Text.pack prUrlString

prUrlString :: String
prUrlString = "https://github.com/o/r/pull/1"

-- | The branch's PR as @gh pr view --json@ prints it: draft or not, and its GitHub state.
pullRequest :: Bool -> String -> String
pullRequest isDraft prState =
    "{\"url\":\""
        <> prUrlString
        <> "\",\"baseRefName\":\"main\",\"headRefName\":\"feat\",\"isDraft\":"
        <> (if isDraft then "true" else "false")
        <> ",\"state\":\""
        <> prState
        <> "\"}"

-- | A temp worktree, its notes, the file the scripted @gh@ reads, and the environment of every call.
data Repo = Repo
    { root :: FilePath
    , work :: FilePath
    , notes :: FilePath
    , prJson :: FilePath
    , env :: [(String, String)]
    }

withRepo :: (Repo -> IO ()) -> IO ()
withRepo test = withSystemTempDirectory "state-e2e" $ \root -> do
    inherited <- getEnvironment
    sh <- fromMaybe (error "no sh on PATH") <$> findExecutable "sh"
    let bin = root </> "bin"
        prJson = root </> "pr.json"
        path = bin <> maybe "" (":" <>) (lookup "PATH" inherited)
        fixed =
            [ ("PATH", path)
            , ("HOME", root)
            , ("XDG_STATE_HOME", root </> ".local" </> "state")
            , ("GIT_CONFIG_NOSYSTEM", "1")
            , ("GIT_AUTHOR_NAME", "e2e")
            , ("GIT_AUTHOR_EMAIL", "e2e@example.com")
            , ("GIT_COMMITTER_NAME", "e2e")
            , ("GIT_COMMITTER_EMAIL", "e2e@example.com")
            ]
        repo =
            Repo
                { root
                , work = root </> "work"
                , notes = root </> "notes"
                , prJson
                , env = fixed <> [kv | kv@(name, _) <- inherited, name `notElem` map fst fixed]
                }
    createDirectory bin
    -- `gh pr view [<url>] --json ...` as gh answers it: the PR a URL names, open
    -- for review on the branch; else the branch's PR, or none.
    writeExecutable (bin </> "gh") . unlines $
        [ "#!" <> sh
        , "case \"$3\" in https://*) printf '{\"url\":\"%s\",\"baseRefName\":\"main\",\"headRefName\":\"feat\",\"isDraft\":false,\"state\":\"OPEN\"}' \"$3\"; exit 0;; esac"
        , "if [ -f '" <> prJson <> "' ]; then cat '" <> prJson <> "'"
        , "else echo 'no pull requests found for branch \"feat\"' >&2; exit 1; fi"
        ]
    git repo {work = root} ["init", "-q", "--bare", "origin.git"]
    git repo {work = root} ["init", "-q", "-b", "main", "work"]
    git repo ["commit", "-q", "--allow-empty", "-m", "base"]
    git repo ["remote", "add", "origin", root </> "origin.git"]
    git repo ["push", "-q", "origin", "main"]
    git repo ["checkout", "-q", "-b", "feat"]
    test repo

writeExecutable :: FilePath -> String -> IO ()
writeExecutable file content = do
    writeFile file content
    setPermissions file . setOwnerExecutable True =<< getPermissions file

-- | Appends a line to one file and commits it: one changed line each time.
commitLine :: Repo -> IO ()
commitLine repo = do
    appendFile (repo.work </> "change.txt") "line\n"
    git repo ["add", "change.txt"]
    git repo ["commit", "-q", "-m", "change"]

git :: Repo -> [String] -> IO ()
git repo = void . gitOut repo

gitOut :: Repo -> [String] -> IO String
gitOut repo argv =
    readCreateProcessWithExitCode
        (proc "git" argv) {cwd = Just repo.work, env = Just repo.env}
        ""
        >>= \case
            (ExitSuccess, out, _) -> pure out
            (ExitFailure _, _, err) -> fail ("git " <> unwords argv <> ": " <> err)
