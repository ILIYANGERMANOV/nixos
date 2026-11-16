{- | @state@'s commands over the test doubles: what each prints, its exit and
the log it writes. The e2e specs prove the same over a real repo and binary.
-}
module State.Cli.Shell.MainSpec (spec) where

import Data.ByteString qualified as BS
import Data.Foldable (for_)
import Data.IORef (IORef, modifyIORef', readIORef)
import Data.List (isSuffixOf)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)
import State.Category.Fuel (Fuel (Max))
import State.Cli.Command (help)
import State.Cli.Render qualified as Render
import State.Cli.Shell.World
import State.Protocol.Advice (PrView (..), Readiness (..))
import State.Run.Codec (logOf)
import State.Run.Event (Branch (..), Envelope (..), FlowName (TenXFlow), Repo (..), SessionId (..), Task (..))
import State.Run.RunGen (breakdownJson, loadSteps, plainTask, roundTask)
import State.Step.Artifact (shellPath)
import System.FilePath ((</>))
import Test.Hspec (Spec, before, describe, it, runIO, shouldBe, shouldContain, shouldReturn, shouldSatisfy)

spec :: Spec
spec = describe "state over the doubles" $ do
    table <- runIO loadSteps
    before newWorld $ do
        describe "init" $ do
            it "starts a run with an id from the entropy, and its log, naming its notes dir and worktree" $ \world -> do
                ran <- state world ["init", "--notes", "/notes"]

                (ran.code, ran.out, ran.err) `shouldBe` (0, ["started 00010203", "run 00010203 /notes /work"], [])
                loggedEvents world `shouldReturn` ["started"]

            it "resumes the run whichever way its notes dir is spelled" $ \world -> do
                run <- startedRun world

                again <- succeeded =<< state world ["init", "--notes", "/notes/"]
                dotted <- succeeded =<< state world ["init", "--notes", "/./notes"]

                (again, dotted) `shouldBe` (["resumed " <> run, "run " <> run <> " /notes /work"], ["resumed " <> run, "run " <> run <> " /notes /work"])

            it "resumes the run whose pointer an older init wrote with a trailing slash" $ \world -> do
                run <- startedRun world
                putFile world "/work/.git/state-notes" "/notes/\n"

                again <- succeeded =<< state world ["init", "--notes", "/notes"]

                again `shouldBe` ["resumed " <> run, "run " <> run <> " /notes /work"]

            it "refuses another run over the worktree's unfinished one, keeping the pointer" $ \world -> do
                run <- startedRun world

                refused <- state world ["init", "--notes", "/other"]
                shown <- succeeded =<< state world ["show"]

                (refused.code, refused.out, refused.err)
                    `shouldBe` ( 2
                               , []
                               ,
                                   [ "state init: --notes /other - the worktree holds unfinished run " <> run <> " in /notes"
                                   , "fix: state init --notes /notes resumes it, or state stop <reason> <why> ends it"
                                   ]
                               )
                take 1 shown `shouldBe` ["run: " <> run <> " (engineer)"]

            it "starts a run in another notes dir once the worktree's run stopped" $ \world -> do
                _ <- startedRun world
                _ <- succeeded =<< state world ["stop", "replan", "the", "plan", "is", "wrong"]

                ran <- state world ["init", "--notes", "/other"]

                (ran.code, ran.out) `shouldBe` (0, ["started 04050607", "run 04050607 /other /work"])

            it "starts a run over a pointer whose log is gone" $ \world -> do
                putFile world "/work/.git/state-notes" "/gone\n"

                ran <- state world ["init", "--notes", "/notes"]

                ran.code `shouldBe` 0

            it "starts a run once per notes dir, and refuses one there after it stopped" $ \world -> do
                run <- startedRun world
                again <- succeeded =<< state world ["init", "--notes", Text.pack notes]
                _ <- succeeded =<< state world ["stop", "replan", "the", "plan", "is", "wrong"]

                refused <- state world ["init", "--notes", "/notes"]

                again `shouldBe` ["resumed " <> run, "run " <> run <> " /notes /work"]
                (refused.code, refused.err)
                    `shouldBe` (2, ["state init: --notes /notes - its run " <> run <> " stopped: replan the plan is wrong", "fix: state init --notes <a new dir>"])

            it "refuses a run in a notes dir whose run finished" $ \world -> do
                _ <- drive world trivialPath
                shown : _ <- succeeded =<< state world ["show"]
                let run = Text.takeWhile (/= ' ') (Text.drop (Text.length "run: ") shown)

                refused <- state world ["init", "--notes", Text.pack notes]

                (refused.code, refused.err)
                    `shouldBe` (2, ["state init: --notes " <> Text.pack notes <> " - its run " <> run <> " finished", "fix: state init --notes <a new dir>"])

            it "stamps each line with the clock, HEAD and the session STATE_SESSION names" $ \world -> do
                modifyIORef' world (\w -> w {env = Map.insert "STATE_SESSION" "s9" w.env, commits = 3})

                _ <- startedRun world

                [line] <- logged world
                w <- readIORef world
                (line.ts, line.head, line.session) `shouldBe` (w.clock, Just (headOf 3), Just (SessionId "s9"))

            it "is an outage, exit 1, when the disk fails" $ \world -> do
                modifyIORef' world (\w -> w {gitDir = Right "/gone/.git"})

                ran <- state world ["init", "--notes", "/notes"]

                ran.code `shouldBe` 1
                take 1 ran.err `shouldSatisfy` all ("state init: a disk or git failure - " `Text.isPrefixOf`)

            it "refuses outside a git work tree, with exit 2" $ \world -> do
                modifyIORef' world (\w -> w {gitDir = Left "git rev-parse --absolute-git-dir: fatal: not a git repository"})

                ran <- state world ["init", "--notes", "/notes"]

                (ran.code, ran.err)
                    `shouldBe` (2, ["state init: not inside a git work tree - git rev-parse --absolute-git-dir: fatal: not a git repository", "fix: cd <worktree>; state keeps one run per worktree"])

        describe "next" $ do
            it "runs the engineer flow at Balanced from init to ready" $ \world -> do
                transcript <- drive world balancedPath

                done <- succeeded =<< state world ["next"]

                transcript `shouldBe` balancedTranscript
                take 5 done
                    `shouldBe` ["DONE " <> prUrl, "  at the end: the flow is done", "  fuel: balanced", "  changed lines: 1", "  PR: " <> prUrl <> " (draft)"]

            it "logs the skips a Low run's agent records for a trivial task" $ \world -> do
                transcript <- drive world trivialPath

                done <- succeeded =<< state world ["next"]

                transcript `shouldBe` trivialTranscript
                take 1 done `shouldBe` ["DONE " <> prUrl]

            for_ ["balanced", "max"] $ \fuel ->
                it ("goes from the simplified plan straight to confirm at " <> Text.unpack fuel) $ \world -> do
                    transcript <- drive world [Record ["fuel", fuel], Record ["gather.enough"], Planned, Handback "researcher" ready]

                    drop 2 transcript `shouldBe` ["plan.done -> simplify_plan", "simplify_plan.done -> confirm"]

            -- The agent's call, a fact line of next: never recorded for it, and Confirm is asked all the same.
            for_ [("low", lowSkips), ("balanced", []), ("max", [])] $ \(fuel, skips) ->
                it ("leaves simplify_plan and refactor to the agent only at Low, and asks Confirm, at " <> Text.unpack fuel) $ \world -> do
                    outs <- driveOut world (Record ["fuel", fuel] : toImplement)
                    _ : confirm <- succeeded =<< state world ["ask", "--kind", "Confirm", "the", "plan", "holds?"]

                    let said = concat outs
                    (filter ("skip it when the task is trivial" `Text.isInfixOf`) said, filter ("ASK Confirm" `Text.isPrefixOf`) said, confirm)
                        `shouldBe` (skips, ["ASK Confirm the simplified plan: confirmed, or adjusted?"], ["ASK user"])

            it "prints each record it advises with its arguments" $ \world -> do
                _ <- drive world [Record ["fuel", "balanced"], Record ["gather.enough"]]

                advice <- succeeded =<< state world ["next"]

                take 1 advice `shouldBe` ["RUN state record plan.done <path>"]

            it "goes on without GitHub when gh cannot be read, saying why" $ \world -> do
                _ <- startedRun world
                modifyIORef' world (\w -> w {pr = PrViewTimedOut 10})

                advice <- succeeded =<< state world ["next"]

                advice `shouldContain` ["  PR sync skipped - gh pr view timed out after 10s"]

            it "says the changed lines are unknown when origin lacks the PR's base" $ \world -> do
                _ <- drive world [Record ["fuel", "balanced"]]
                modifyIORef' world (\w -> w {pr = prOn "gone" IsDraft})

                advice <- succeeded =<< state world ["next"]

                advice `shouldSatisfy` any ("  changed lines unknown - git diff --numstat origin/gone...HEAD: " `Text.isPrefixOf`)

            it "refuses with no run in the worktree, with exit 2" $ \world -> do
                ran <- state world ["next"]

                (ran.code, ran.err)
                    `shouldBe` (2, ["state next: no run in this worktree - no state init ran here", "fix: state init --notes /tmp/engineer-<owner>-<repo>-<slug>"])

            it "names a hand-edited bad line and appends nothing after it" $ \world -> do
                _ <- drive world []
                editLog world (<> "{\"v\":3,broken\n")
                before' <- logBytes world

                for_ [("next", []), ("show", []), ("record", ["fuel", "max"])] $ \(sub, args) -> do
                    bad <- state world (sub : args)
                    (bad.code, map (fst . Text.breakOn " - ") bad.err)
                        `shouldBe` (2, ["state " <> sub <> ": /notes/events.jsonl line 2 is not read", "fix: repair or move /notes/events.jsonl"])
                after <- logBytes world
                after `shouldBe` before'

            it "names the recovery for an older state's log: set it aside, start fresh" $ \world -> do
                _ <- drive world []
                editLog world (const "{\"seq\":0,\"ts\":\"t\",\"head\":null,\"session\":null,\"event\":{\"type\":\"started\",\"notes\":\"n\",\"version\":2}}\n")

                old <- state world ["next"]

                (old.code, old.err)
                    `shouldBe` (2, ["state next: /notes/events.jsonl line 1 is not read - log version 2, this state reads 4", "fix: move the old run aside and start fresh: mv /notes /notes.old, then state init --notes /notes"])

        describe "record" $ do
            it "refuses an event with no arrow: exit 2, a fix line, the refusal logged, and next warns" $ \world -> do
                _ <- drive world [Record ["fuel", "balanced"]]

                refused <- state world ["record", "ready.done", prUrl]

                (refused.code, refused.out, refused.err)
                    `shouldBe` (2, [], ["state record: ready.done - no such arrow out of gather", "fix: state record research.spawned | state record gather.enough"])
                events <- loggedEvents world
                last events `shouldBe` "refused"
                warned <- succeeded =<< state world ["next"]
                take 3 warned
                    `shouldBe` ["RUN one option below", "refused: ready.done - no such arrow out of gather", "fix: state record research.spawned | state record gather.enough"]

            it "fixes a refused event by the arrows this Fuel takes, never a skip it refuses" $ \world -> do
                _ <- drive world toSimplifyPr

                refused <- state world ["record", "await_ci.green"]

                (refused.code, refused.err)
                    `shouldBe` (2, ["state record: await_ci.green - no such arrow out of simplify_pr", "fix: state record simplify_pr.done"])

            it "appends the event and prints it with where the run is now" $ \world -> do
                _ <- startedRun world

                ran <- state world ["record", "fuel", "max"]

                (ran.code, ran.out, ran.err) `shouldBe` (0, ["recorded 2 fuel -> gather"], [])
                loggedEvents world `shouldReturn` ["started", "fuel"]

            it "names a usage error with exit 2, lists the events and writes nothing" $ \world -> do
                _ <- startedRun world

                ran <- state world ["record"]

                (ran.code, take 1 ran.err) `shouldBe` (2, ["Missing: EVENT"])
                ran.err `shouldSatisfy` any (Text.isPrefixOf "  fuel ")
                loggedEvents world `shouldReturn` ["started"]

        describe "handback" $ do
            it "records a role's hand-back from stdin" $ \world -> do
                _ <- drive world [Record ["fuel", "balanced"], Record ["gather.enough"], Planned]

                ran <- stateIn world "READY\nDone.\n" ["handback", "researcher"]

                (ran.code, ran.err) `shouldBe` (0, [])
                recorded ran.out `shouldBe` ["simplify_plan.done -> confirm"]

            it "advises a worker's BLOCKED for triage until the run asks it as its own" $ \world -> do
                _ <- drive world ([Record ["fuel", "balanced"]] <> init toImplement)
                _ <- succeeded =<< stateIn world "BLOCKED no access\n" ["handback", "implementer"]

                blocked <- succeeded =<< state world ["next"]
                asked : _ <- succeeded =<< state world ["ask", "--kind", "Pick", "--from", "implementer", "retry", "with", "a", "token?"]
                _ <- succeeded =<< state world ["rule", Text.drop (Text.length "asked ") asked, "--answer", "retry", "--why", "token granted", "--cost", "none"]
                ruled <- succeeded =<< state world ["next"]

                take 1 blocked `shouldBe` ["RUN state ask --kind <kind> --from implementer <question> - triage: BLOCKED no access"]
                ruled `shouldSatisfy` (not . any ("triage: BLOCKED no access" `Text.isInfixOf`))

            it "refuses a hand-back that is not UTF-8, with exit 2" $ \world -> do
                _ <- startedRun world

                ran <- stateIn world "READY\n\xff\n" ["handback", "researcher"]

                (ran.code, ran.err) `shouldBe` (2, ["state handback: the hand-back - stdin is not UTF-8", "fix: state help"])
                loggedEvents world `shouldReturn` ["started"]

            it "refuses a role the flows do not know, with exit 2" $ \world -> do
                _ <- startedRun world

                ran <- stateIn world "READY\n" ["handback", "nobody"]

                ran.code `shouldBe` 2
                take 1 ran.err `shouldSatisfy` all ("state handback: " `Text.isPrefixOf`)

        describe "override" $ do
            it "names the PR ready.done recorded in a run that skipped its draft" $ \world -> do
                _ <- drive world [Record ["fuel", "balanced"], Override "ready", Record ["ready.done", prUrl]]

                done <- succeeded =<< state world ["next"]

                take 1 done `shouldBe` ["DONE " <> prUrl]

            it "overrides to a named state, which show then names" $ \world -> do
                _ <- drive world []

                moved <- succeeded =<< state world ["override", "review", "resume", "after", "a", "crash"]

                moved `shouldBe` ["recorded 2 overridden -> review"]
                shown <- succeeded =<< state world ["show"]
                shown `shouldContain` ["step: review"]

            it "refuses an override to an unknown state, listing the states" $ \world -> do
                _ <- drive world []

                refused <- state world ["override", "nowhere", "why"]

                (refused.code, refused.err)
                    `shouldBe` ( 2
                               ,
                                   [ "state override: override to nowhere - the flow has no single state of that name"
                                   , "fix: state override <gather|plan|simplify_plan|confirm|draft|implement|refactor|review|pick|fix|re_review|describe|simplify_pr|await_ci|fix_pr|ready> <why>"
                                   ]
                               )

            it "needs a state and why" $ \world -> do
                ran <- state world ["override", "review"]

                (ran.code, take 1 ran.err) `shouldBe` (2, ["Missing: <why>"])

        describe "the review loop" $ do
            it "asks Stuck when rounds 1 and 2 pick the same row" $ \world -> do
                _ <- drive world (atReview <> reviewRound "R1" [] <> [Handback "fixer" ready] <> reviewRound "R1" [])

                advice <- succeeded =<< state world ["next"]

                take 1 advice `shouldBe` ["ASK Stuck the fix loop repeats R1: go on, change course, or stop?"]

            it "refuses a pick.loop past Balanced's 3 re-reviews, then exits by pick.final" $ \world -> do
                let rounds = concat [reviewRound label [] <> [Handback "fixer" ready] | label <- ["R1", "R2", "R3"]]
                _ <- drive world (atReview <> rounds <> [Handback "review-lead" reviewed])

                advice <- succeeded =<< state world ["next"]
                refused <- state world ["record", "pick.loop", "--row", "R4"]
                exited <- succeeded =<< state world ["record", "pick.final"]

                (take 1 advice, filter ("  Re-reviews: " `Text.isPrefixOf`) advice)
                    `shouldBe` (["RUN state record pick.final [--row <label>]... [--verdict <requirement>=<met|not-met|unverified>]..."], ["  Re-reviews: 3 of 3 used, none left"])
                (refused.code, refused.err)
                    `shouldBe` (2, ["state record: the spend at pick - Re-reviews allows 3 at this Fuel, all spent", "fix: state record pick.final [--row <label>]... [--verdict <requirement>=<met|not-met|unverified>]..."])
                recorded exited `shouldBe` ["pick.final -> describe"]

        it "puts every ruling of a child run in show and in its hand-back" $ \world -> do
            parent <- tenXAtFanOut world
            child <- childRun world parent "/child" "t1"
            [asked, _] <- succeeded =<< state world ["ask", "--kind", "Pick", "which", "lib?"]
            let qid = Text.drop (Text.length "asked ") asked
                ruling = "Ruling " <> qid <> " Pick: zod - already used - none"
            _ <- succeeded =<< state world ["rule", qid, "--answer", "zod", "--why", "already used", "--cost", "none"]

            shown <- succeeded =<< state world ["show"]
            forwarded <- succeeded =<< state world ["ask", "--kind", "Design", "which", "store?"]
            stopped <- succeeded =<< state world ["stop", "failed", "no", "access"]

            shown `shouldContain` ["rulings:", "  " <> ruling]
            forwarded `shouldContain` [ruling]
            stopped `shouldBe` ["stopped", "HANDBACK FAILED no access", "Run: " <> child, ruling]

        it "shows a forwarded question with the answer that came down for it" $ \world -> do
            _ <- startedRun world
            [asked, _] <- succeeded =<< state world ["ask", "--kind", "Design", "which", "store?"]
            let qid = Text.drop (Text.length "asked ") asked
            _ <- succeeded =<< state world ["answer", qid, "postgres"]

            shown <- succeeded =<< state world ["show"]

            shown `shouldContain` ["answered:", "  " <> qid <> " Design: which store? - postgres"]

        describe "the 10x" $ do
            it "spawns the first task, the second waiting on it" $ \world -> do
                _ <- tenXAtFanOut world

                advised <- succeeded =<< state world ["next"]

                take 1 advised `shouldBe` ["SPAWN engineer --task t1 background: yes"]

            it "spawns a task's child as the role leading its task's flow" $ \world -> do
                _ <- tenXAtFanOutOf world [(plainTask "t1" []) {flow = TenXFlow}]

                advised <- succeeded =<< state world ["next"]

                take 1 advised `shouldBe` ["SPAWN 10x --task t1 background: yes"]

            it "logs a child's spawn in its parent's log once, a retried init joining the same run" $ \world -> do
                parent <- tenXAtFanOut world

                child <- childRun world parent "/child" "t1"
                again <- succeeded =<< state world ["init", "--notes", "/child", "--parent", parent, "--parent-log", Text.pack eventsPath, "--task", "t1"]

                again `shouldBe` ["resumed " <> child, "run " <> child <> " /child /child-work"]
                filter (== "spawned") <$> loggedEvents world `shouldReturn` ["spawned"]

            it "starts a child on the flow its parent's fan-out runs" $ \world -> do
                parent <- tenXAtFanOut world

                child <- childRun world parent "/child" "t1"
                shown <- succeeded =<< state world ["show"]

                take 1 shown `shouldBe` ["run: " <> child <> " (engineer)"]

            it "refuses a child --flow other than its task's, logging no spawn" $ \world -> do
                parent <- tenXAtFanOut world
                atWorktree world childWorktree

                refused <- state world ["init", "--notes", "/child", "--flow", "10x", "--parent", parent, "--parent-log", Text.pack eventsPath, "--task", "t1"]

                (refused.code, refused.err)
                    `shouldBe` (2, ["state init: --flow 10x - task t1 runs the engineer flow", "fix: state brief engineer --task t1, in the parent's worktree, prints the init line"])
                filter (== "spawned") <$> loggedEvents world `shouldReturn` []

            it "starts a 10x child for a task whose flow is 10x, --flow named or not" $ \world -> do
                parent <- tenXAtFanOutOf world [(plainTask "t1" []) {flow = TenXFlow}, (plainTask "t2" []) {flow = TenXFlow}]
                atWorktree world childWorktree
                named <- succeeded =<< state world ["init", "--notes", "/child", "--flow", "10x", "--parent", parent, "--parent-log", Text.pack eventsPath, "--task", "t1"]
                namedShown <- succeeded =<< state world ["show"]
                atWorktree world "/other-work"
                _ <- succeeded =<< state world ["init", "--notes", "/other", "--parent", parent, "--parent-log", Text.pack eventsPath, "--task", "t2"]
                unnamedShown <- succeeded =<< state world ["show"]

                map (Text.takeWhile (/= ' ')) named `shouldBe` ["started", "run"]
                map (take 1) [namedShown, unnamedShown] `shouldSatisfy` all (all (" (10x)" `Text.isSuffixOf`))

            it "refuses an engineer child for a task whose flow is 10x" $ \world -> do
                parent <- tenXAtFanOutOf world [(plainTask "t1" []) {flow = TenXFlow}]
                atWorktree world childWorktree

                refused <- state world ["init", "--notes", "/child", "--flow", "engineer", "--parent", parent, "--parent-log", Text.pack eventsPath, "--task", "t1"]

                (refused.code, refused.err)
                    `shouldBe` (2, ["state init: --flow engineer - task t1 runs the 10x flow", "fix: state brief 10x --task t1, in the parent's worktree, prints the init line"])

            it "starts a child at its task's Fuel, so its first next is the step, in the foreground" $ \world -> do
                parent <- tenXAtFanOutOf world [(plainTask "t1" []) {fuel = Max}]
                _ <- childRun world parent "/child" "t1"

                advised <- succeeded =<< state world ["next"]

                take 1 advised `shouldBe` ["RUN one option below"]
                advised `shouldSatisfy` any ("spawn a researcher in the foreground - " `Text.isInfixOf`)
                -- Max's researcher budget: Balanced, the default, caps it.
                filter ("Researchers: " `Text.isInfixOf`) advised `shouldBe` ["  Researchers: 0 used, one per group"]

            it "starts a child whose --flow names its parent's fan-out's" $ \world -> do
                parent <- tenXAtFanOut world
                atWorktree world childWorktree

                accepted <- state world ["init", "--notes", "/child", "--flow", "engineer", "--parent", parent, "--parent-log", Text.pack eventsPath, "--task", "t1"]

                (accepted.code, map (Text.takeWhile (/= ' ')) accepted.out) `shouldBe` (0, ["started", "run"])

            it "refuses a child for a task the parent's breakdown lacks, logging no spawn" $ \world -> do
                parent <- tenXAtFanOut world
                atWorktree world childWorktree

                refused <- state world ["init", "--notes", "/child", "--parent", parent, "--parent-log", Text.pack eventsPath, "--task", "t9"]

                (refused.code, refused.err)
                    `shouldBe` (2, ["state init: --task t9 - the parent's breakdown has no such task", "fix: state brief engineer, in the parent's worktree, prints the init line"])
                filter (== "spawned") <$> loggedEvents world `shouldReturn` []

            it "refuses a child its parent cannot take, leaving its worktree no run" $ \world -> do
                parent <- startedRun world
                atWorktree world childWorktree

                ran <- state world ["init", "--notes", "/child", "--parent", parent, "--parent-log", Text.pack eventsPath, "--task", "t1"]
                shown <- state world ["show"]

                (ran.code, shown.code) `shouldBe` (2, 2)
                take 1 shown.err `shouldBe` ["state show: no run in this worktree - no state init ran here"]

            it "records a child's hand-back that names its run, and refuses one that does not" $ \world -> do
                parent <- tenXAtFanOut world
                child <- childRun world parent "/child" "t1"
                atWorktree world "/work"

                unnamed <- stateIn world "READY https://pr/1\n" ["handback", "engineer"]
                named <- stateIn world (encodeUtf8 ("READY https://pr/1\nRun: " <> child <> "\n")) ["handback", "engineer"]

                unnamed.code `shouldBe` 2
                (named.code, recorded named.out) `shouldBe` (0, ["handed_back -> engineers", "task -> engineers"])

            it "hands a child's question up once, however its log grew before next delivered it again" $ \world -> do
                parent <- tenXAtFanOut world
                _ <- childRun world parent "/child" "t1"
                _ <- succeeded =<< state world ["ask", "--kind", "Design", "which", "store?"]
                once <- loggedEvents world
                _ <- succeeded =<< state world ["record", "fuel", "balanced"]

                again <- succeeded =<< state world ["next"]

                take 1 again `shouldSatisfy` all ("HANDBACK NEEDS_DECISION Design " `Text.isPrefixOf`)
                again `shouldSatisfy` (not . any ("parent: " `Text.isPrefixOf`))
                loggedEvents world `shouldReturn` once

            it "writes the top's answer down to every run below, each resuming the next with it" $ \world -> do
                (_, mid, grand) <- threeLevels world
                let qid = grand <> ":1"
                climbed world qid

                answered <- succeeded =<< state world ["answer", qid, "postgres"]
                topNext <- succeeded =<< state world ["next"]
                atWorktree world midWorktree
                midNext <- succeeded =<< state world ["next"]
                atWorktree world grandWorktree
                grandShown <- succeeded =<< state world ["show"]

                answered `shouldBe` ["answered " <> qid]
                take 1 topNext `shouldBe` ["RESUME " <> mid <> " with the answer to " <> qid <> ": postgres"]
                take 1 midNext `shouldBe` ["RESUME " <> grand <> " with the answer to " <> qid <> ": postgres"]
                grandShown `shouldContain` ["answered:", "  " <> qid <> " Design: which store? - postgres"]
                answersIn world `shouldReturn` [1, 1, 1]

            it "tells an answer it could not write down, and a retry lands it once in every run below" $ \world -> do
                (_, mid, grand) <- threeLevels world
                let qid = grand <> ":1"
                    broken = "{broken\n"
                climbed world qid
                editLogIn world (logOf grandNotes) (<> broken)

                failed <- succeeded =<< state world ["answer", qid, "postgres"]
                editLogIn world (logOf grandNotes) (\bytes -> fromMaybe bytes (BS.stripSuffix broken bytes))
                retried <- succeeded =<< state world ["answer", qid, "postgres"]

                drop 1 failed `shouldSatisfy` \case
                    [why, fix] -> ("child " <> grand <> ": ") `Text.isPrefixOf` why && fix == "fix: state answer " <> qid <> " postgres --by " <> mid <> ", in " <> Text.pack grandWorktree
                    _ -> False
                retried `shouldBe` ["answered " <> qid]
                answersIn world `shouldReturn` [1, 1, 1]

            it "takes the same answer again, appending nothing to any run" $ \world -> do
                (_, _, grand) <- threeLevels world
                let qid = grand <> ":1"
                climbed world qid
                _ <- succeeded =<< state world ["answer", qid, "postgres"]

                same <- succeeded =<< state world ["answer", qid, "postgres"]

                same `shouldBe` ["answered " <> qid]
                answersIn world `shouldReturn` [1, 1, 1]

            it "refuses another answer to a question it holds an answer to" $ \world -> do
                (_, _, grand) <- threeLevels world
                let qid = grand <> ":1"
                climbed world qid
                _ <- succeeded =<< state world ["answer", qid, "postgres"]

                other <- state world ["answer", qid, "sqlite"]

                (other.code, other.err)
                    `shouldBe` (2, ["state answer: another answer to " <> qid <> " - it was answered already: postgres", "fix: state show"])

            it "shows each task, its PR and what is held" $ \world -> do
                _ <- tenXAtFanOut world
                for_ [["task", "t1", "review", prUrl], ["held", "t2", "https://github.com/o/r/issues/9"]] $ \argv -> succeeded =<< state world ("record" : argv)

                shown <- succeeded =<< state world ["show"]

                shown `shouldContain` ["task t1: not started, PR review " <> prUrl <> ", tries 0", "task t2: not started, tries 0, held https://github.com/o/r/issues/9"]

            it "clears a held wake once acted on, keeping the others" $ \world -> do
                _ <- tenXAtFanOut world
                for_ [["held", "t2", "https://pr/2#a"], ["held", "t2", "https://pr/2#b"], ["acted", "t2", "https://pr/2#a"]] $ \argv -> succeeded =<< state world ("record" : argv)

                shown <- succeeded =<< state world ["show"]

                shown `shouldContain` ["task t2: not started, tries 0, held https://pr/2#b"]

            it "briefs an engineer with its task's fields, then its init line" $ \world -> do
                run <- tenXAtFanOut world

                brief <- succeeded =<< state world ["brief", "engineer", "--task", "t2"]

                brief
                    `shouldBe` [ "Task: t2"
                               , "Fuel: Balanced"
                               , "Base: main"
                               , "Branch: t2"
                               , "Depends on: t1"
                               , "QA: no"
                               , "Heavy: yes"
                               , "Security-sensitive: none"
                               , ""
                               , "state init --notes <dir> --parent " <> run <> " --parent-log " <> Text.pack eventsPath <> " --task t2"
                               ]

            it "briefs a 10x task's init line with its flow, whichever lead role asks" $ \world -> do
                run <- tenXAtFanOutOf world [(plainTask "t1" []) {flow = TenXFlow}]

                briefs <- traverse (\role -> succeeded =<< state world ["brief", role, "--task", "t1"]) ["engineer", "10x"]

                map (drop 9) briefs
                    `shouldBe` replicate 2 ["state init --notes <dir> --flow 10x --parent " <> run <> " --parent-log " <> Text.pack eventsPath <> " --task t1"]

            it "briefs an engineer to init in its task's worktree and its repo's notes dir" $ \world -> do
                run <- tenXAtFanOutOf world [(plainTask "t1" []) {branch = Branch "feat/x", repo = Just (Repo "o" "r"), worktree = shellPath "/wt/t1"}]

                brief <- succeeded =<< state world ["brief", "engineer", "--task", "t1"]

                drop 9 brief
                    `shouldBe` ["cd /wt/t1 && state init --notes /tmp/engineer-o-r-feat-x/ --parent " <> run <> " --parent-log " <> Text.pack eventsPath <> " --task t1"]

            it "briefs an engineer a notes dir whose branch slug holds nothing a shell reads" $ \world -> do
                run <- tenXAtFanOutOf world [(plainTask "t1" []) {branch = Branch "feat/x;rm -rf $(y)`z`|w", repo = Just (Repo "o" "r")}]

                brief <- succeeded =<< state world ["brief", "engineer", "--task", "t1"]

                drop 9 brief
                    `shouldBe` ["state init --notes /tmp/engineer-o-r-feat-x-rm--rf---y--z--w/ --parent " <> run <> " --parent-log " <> Text.pack eventsPath <> " --task t1"]

            it "briefs a round task with the PR it stays on" $ \world -> do
                _ <- tenXAtFanOutOf world [roundTask "t1" "https://pr/1"]

                brief <- succeeded =<< state world ["brief", "engineer", "--task", "t1"]

                filter ("Round on PR: " `Text.isPrefixOf`) brief `shouldBe` ["Round on PR: https://pr/1"]

            it "refuses to brief an engineer for a task the breakdown lacks" $ \world -> do
                _ <- tenXAtFanOut world

                ran <- state world ["brief", "engineer", "--task", "t9"]

                ran.code `shouldBe` 2

        describe "brief" $ do
            it "gives a refactorer its step's task and the stop rule" $ \world -> do
                _ <- drive world []

                stopRule <- succeeded =<< state world ["render", "stop-rule"]
                brief <- succeeded =<< state world ["brief", "refactorer"]

                take 1 brief `shouldBe` ["## refactor"]
                brief `shouldSatisfy` (stopRule `isSuffixOf`)

            it "gives a fixer only the step the run is at, and a worker no command of the lead's" $ \world -> do
                _ <- drive world (atReview <> [Commit, Handback "review-lead" reviewed, Record ["pick.loop", "--row", "R1"]])

                fixer <- succeeded =<< state world ["brief", "fixer"]
                workers <- traverse (\role -> succeeded =<< state world ["brief", role]) ["researcher", "implementer", "refactorer", "fixer"]

                filter ("## " `Text.isPrefixOf`) fixer `shouldBe` ["## fix"]
                concat workers `shouldSatisfy` (not . any (\line -> any (`Text.isInfixOf` line) ["state record", "state brief"]))

            it "gives a review-lead the plan-wrong line, not the stop rule" $ \world -> do
                _ <- drive world []

                planWrong <- succeeded =<< state world ["render", "plan-wrong"]
                stopRule <- succeeded =<< state world ["render", "stop-rule"]
                brief <- succeeded =<< state world ["brief", "review-lead"]

                brief `shouldSatisfy` (planWrong `isSuffixOf`)
                brief `shouldSatisfy` (not . any (`elem` stopRule))

        describe "render" $ do
            it "prints a block of the flow without a run" $ \world -> do
                ran <- state world ["render", "stop-rule"]

                (ran.code, ran.out, ran.err) `shouldBe` (0, Text.lines Render.stopRule, [])

            it "refuses a block it does not know, with exit 2" $ \world -> do
                ran <- state world ["render", "nowhere"]

                ran.code `shouldBe` 2
                take 1 ran.err `shouldSatisfy` all ("state render: " `Text.isPrefixOf`)

        describe "usage" $ do
            it "prints help with no command, as help and --help do" $ \world -> do
                ran <- traverse (state world) [[], ["help"], ["--help"]]

                [(r.code, r.out, r.err) | r <- ran] `shouldBe` replicate 3 (0, Text.lines (help table), [])

            it "prints a command's help on stdout, exit 0" $ \world -> do
                ran <- state world ["record", "--help"]

                (ran.code, take 1 ran.out, ran.err) `shouldBe` (0, ["Usage: state record EVENT"], [])

            it "refuses a command it does not know, with exit 2" $ \world -> do
                ran <- state world ["nowhere"]

                (ran.code, take 1 ran.err, ran.out) `shouldBe` (2, ["Invalid argument `nowhere'"], [])

            it "is an outage, exit 1, without the step table STATE_STEPS names" $ \world -> do
                modifyIORef' world (\w -> w {env = Map.delete "STATE_STEPS" w.env})

                ran <- state world ["next"]

                (ran.code, ran.err) `shouldBe` (1, ["state steps: STATE_STEPS is not set - it names the flows' step table", "fix: run the installed state, which sets it"])

{- | A top 10x at its fan-out over a 10x task, that task's 10x child at its
own fan-out, and an engineer grandchild under it, each in its own worktree;
later calls run in the grandchild's. The three runs' ids, top first.
-}
threeLevels :: IORef World -> IO (Text, Text, Text)
threeLevels world = do
    top <- tenXAtFanOutOf world [(plainTask "t1" []) {flow = TenXFlow}]
    atWorktree world midWorktree
    mid <- startedIn world ["--notes", Text.pack midNotes, "--parent", top, "--parent-log", Text.pack eventsPath, "--task", "t1"]
    putFile world (midNotes </> "tasks.json") (breakdownJson [plainTask "t1" []])
    _ <- succeeded =<< state world ["override", "breakdown", "the", "plan", "is", "agreed"]
    _ <- succeeded =<< state world ["record", "breakdown.done", "--tasks", Text.pack (midNotes </> "tasks.json")]
    atWorktree world grandWorktree
    grand <- startedIn world ["--notes", Text.pack grandNotes, "--parent", mid, "--parent-log", Text.pack (logOf midNotes), "--task", "t1"]
    pure (top, mid, grand)

{- | The grandchild asks a Design question, the middle run forwards it, and
the top forwards it to the user; later calls run in the top's worktree.
-}
climbed :: IORef World -> Text -> IO ()
climbed world qid = do
    _ <- succeeded =<< state world ["ask", "--kind", "Design", "which", "store?"]
    atWorktree world midWorktree
    _ <- succeeded =<< state world ["forward", qid]
    atWorktree world "/work"
    _ <- succeeded =<< state world ["forward", qid]
    pure ()

-- | How many answers each run's log holds, top first.
answersIn :: IORef World -> IO [Int]
answersIn world = traverse (fmap (length . filter (== "answered")) . loggedEventsIn world) [eventsPath, logOf midNotes, logOf grandNotes]

midNotes, grandNotes, midWorktree, grandWorktree :: FilePath
midNotes = "/mid"
grandNotes = "/grand"
midWorktree = "/mid-work"
grandWorktree = "/grand-work"

-- | A Balanced run to its first Simplify of the PR.
toSimplifyPr :: [Act]
toSimplifyPr =
    Record ["fuel", "balanced"]
        : toImplement
            <> [Handback "review-lead" reviewed, Record ["pick.final"], Handback "fixer" ready]

balancedPath :: [Act]
balancedPath = toSimplifyPr <> [Handback "fixer" simplified, Record ["await_ci.green"], Record ["ready.done", prUrl]]

balancedTranscript :: [Text]
balancedTranscript =
    [ "fuel -> gather"
    , "research.spawned -> gather"
    , "research.handed_back -> gather"
    , "gather.enough -> plan"
    , "plan.done -> simplify_plan"
    , "simplify_plan.done -> confirm"
    , "confirm.confirmed -> draft"
    , "draft.done -> implement"
    , "implement.done -> refactor"
    , "refactor.skipped -> review"
    , "review.rows -> pick"
    , "pick.final -> describe"
    , "describe.done -> simplify_pr"
    , "simplify_pr.done -> await_ci"
    , "await_ci.green -> ready"
    , "ready.done -> out"
    ]

-- | Low, a trivial task: the agent gathers nothing, skips the proposal and the refactor, so no hand-back of theirs.
trivialPath :: [Act]
trivialPath =
    [ Record ["fuel", "low"]
    , Record ["gather.enough"]
    , Planned
    , Record ["simplify_plan.skipped"]
    , Record ["confirm.confirmed"]
    , OpenPr
    , Commit
    , Handback "implementer" ready
    , Record ["refactor.skipped", "a", "one-line", "change"]
    , Handback "review-lead" reviewed
    , Record ["pick.final"]
    , Handback "fixer" ready
    , Handback "fixer" simplified
    , Record ["await_ci.green"]
    , Record ["ready.done", prUrl]
    ]

trivialTranscript :: [Text]
trivialTranscript =
    [ "fuel -> gather"
    , "gather.enough -> plan"
    , "plan.done -> simplify_plan"
    , "simplify_plan.skipped -> confirm"
    , "confirm.confirmed -> draft"
    , "draft.done -> implement"
    , "implement.done -> refactor"
    , "refactor.skipped -> review"
    , "review.rows -> pick"
    , "pick.final -> describe"
    , "describe.done -> simplify_pr"
    , "simplify_pr.done -> await_ci"
    , "await_ci.green -> ready"
    , "ready.done -> out"
    ]

-- | What next says a Low run's agent may skip, at simplify_plan and refactor.
lowSkips :: [Text]
lowSkips =
    [ "  Low: skip it when the task is trivial: state record simplify_plan.skipped"
    , "  Low: skip it when the task is trivial: state record refactor.skipped <why>"
    ]

-- | Balanced, moved to the review by override.
atReview :: [Act]
atReview = [Record ["fuel", "balanced"], Override "review"]

-- | A review back with its rows, and the lead's picks: a loop on this row.
reviewRound :: Text -> [Text] -> [Act]
reviewRound label verdicts = [Commit, Handback "review-lead" reviewed, Record (["pick.loop", "--row", label] <> verdicts)]
