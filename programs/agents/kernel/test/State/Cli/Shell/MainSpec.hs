{- | @state@'s commands over the test doubles: what each prints, its exit and
the log it writes. The e2e specs prove the same over a real repo and binary.
-}
module State.Cli.Shell.MainSpec (spec) where

import Data.Foldable (for_)
import Data.IORef (IORef, modifyIORef', readIORef)
import Data.List (isSuffixOf)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)
import State.Category.Fuel (Fuel (Max))
import State.Cli.Command (help)
import State.Cli.Render qualified as Render
import State.Cli.Shell.World
import State.Protocol.Advice (PrView (..), Readiness (..))
import State.Run.Event (Branch (..), Envelope (..), FlowName (TenXFlow), PlanCall (..), Repo (..), SessionId (..), Task (..))
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

            it "starts afresh over a pointer that names no run id, as an older init's notes dir" $ \world -> do
                putFile world "/work/.git/state-run" "/notes/\n"

                ran <- state world ["init", "--notes", "/notes"]

                (ran.code, take 1 ran.out) `shouldBe` (0, ["started 00010203"])

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

            it "prints the chief's next step to the init of the flow its branch runs, starting no run" $ \_ ->
                for_ [("engineer", []), ("10x", ["--flow", "10x"]), ("architect", ["--flow", "architect"])] $ \(branch, flag) -> do
                    fresh <- newWorld
                    chief <- startedIn fresh ["--flow", "chief"]
                    _ <- succeeded =<< state fresh ["record", "fuel.set", "balanced"]
                    _ <- succeeded =<< state fresh ["record", "route." <> branch]
                    next <- succeeded =<< state fresh ["next"]
                    before' <- loggedEvents fresh

                    inner <- succeeded =<< state fresh (["init", "--notes", "/tmp/inner"] <> flag)

                    after <- loggedEvents fresh
                    shown <- succeeded =<< state fresh ["show"]
                    (inner, after, take 1 shown) `shouldBe` (next, before', ["run: " <> chief <> " (chief)"])

            it "starts an engineer, 10x, architect or chief run in a free worktree, only the 10x past its Fuel at Balanced" $ \_ ->
                for_ [([], ["started"]), (["--flow", "10x"], ["started", "fuel.set"]), (["--flow", "architect"], ["started"]), (["--flow", "chief"], ["started"])] $ \(flag, begun) -> do
                    fresh <- newWorld

                    ran <- state fresh (["init", "--notes", "/notes"] <> flag)

                    events <- loggedEvents fresh
                    (ran.code, ran.out, ran.err, events) `shouldBe` (0, ["started 00010203", "run 00010203 /notes /work"], [], begun)

            it "refuses an engineer, 10x or architect init over a run no branch of which runs that flow, as before" $ \_ -> do
                let engineer = []
                    tenX = ["--flow", "10x"]
                    architect = ["--flow", "architect"]
                    chief = ["--flow", "chief"]
                    standalone = [(held, [], flag) | held <- [engineer, tenX, architect], flag <- [engineer, tenX, architect]]
                    atHub = [(chief, [], flag) | flag <- [engineer, tenX, architect]]
                    requested pick = [["fuel.set", "balanced"], [pick]]
                    otherBranch = [(chief, requested "route.engineer", tenX), (chief, requested "route.engineer", architect), (chief, requested "route.10x", engineer)]
                    inBlocks = [(chief, requested "route.blocks", flag) | flag <- [engineer, tenX, architect]]
                for_ (standalone <> atHub <> otherBranch <> inBlocks) $ \(held, picks, flag) -> do
                    fresh <- newWorld
                    run <- startedIn fresh held
                    for_ picks $ \argv -> succeeded =<< state fresh ("record" : argv)

                    refused <- state fresh (["init", "--notes", "/other"] <> flag)

                    (refused.code, refused.out, refused.err)
                        `shouldBe` (2, [], ["state init: --notes /other - the worktree holds unfinished run " <> run <> " in /notes", "fix: state init --notes /notes resumes it, or state stop <reason> <why> ends it"])

            it "starts a run in another notes dir once the worktree's run stopped" $ \world -> do
                _ <- startedRun world
                _ <- succeeded =<< state world ["stop", "replan", "the", "plan", "is", "wrong"]

                ran <- state world ["init", "--notes", "/other"]

                (ran.code, ran.out) `shouldBe` (0, ["started 04050607", "run 04050607 /other /work"])

            it "starts a run over a pointer whose run is gone" $ \world -> do
                putFile world "/work/.git/state-run" "deadbeef\n"

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
                    transcript <- drive world ([Record ["fuel.set", fuel]] <> gathered <> [Planned, Handback "researcher" ready])

                    drop 3 transcript `shouldBe` ["plan.done -> skip_simplify_plan", "skip_simplify_plan.run -> simplify_plan", "simplify_plan.done -> confirm"]

            -- The agent's call, a fact line of next: never recorded for it, so at Low the agent runs the proposal, and Confirm is asked all the same.
            for_ [("low", lowSkips, ranProposal), ("balanced", [], toImplement), ("max", [], toImplement)] $ \(fuel, skips, acts) ->
                it ("leaves simplify_plan and refactor to the agent only at Low, and asks Confirm, at " <> Text.unpack fuel) $ \world -> do
                    outs <- driveOut world (Record ["fuel.set", fuel] : acts)
                    _ : confirm <- succeeded =<< state world ["ask", "--kind", "Confirm", "the", "plan", "holds?"]

                    let said = concat outs
                    (filter ("skip it when the task is trivial" `Text.isInfixOf`) said, filter ("ASK Confirm" `Text.isPrefixOf`) said, confirm)
                        `shouldBe` (skips, ["ASK Confirm the simplified plan: confirmed, or adjusted?"], ["ASK user"])

            it "prints each record it advises with its arguments" $ \world -> do
                _ <- drive world (Record ["fuel.set", "balanced"] : gathered)

                advice <- succeeded =<< state world ["next"]

                take 1 advice `shouldBe` ["RUN state record plan.done <path>"]

            it "goes on without GitHub when gh cannot be read, saying why" $ \world -> do
                _ <- startedRun world
                modifyIORef' world (\w -> w {pr = PrViewTimedOut 10})

                advice <- succeeded =<< state world ["next"]

                advice `shouldContain` ["  PR sync skipped - gh pr view timed out after 10s"]

            it "says the changed lines are unknown when origin lacks the PR's base" $ \world -> do
                _ <- drive world [Record ["fuel.set", "balanced"]]
                modifyIORef' world (\w -> w {pr = prOn "gone" IsDraft})

                advice <- succeeded =<< state world ["next"]

                advice `shouldSatisfy` any ("  changed lines unknown - git diff --numstat origin/gone...HEAD: " `Text.isPrefixOf`)

            it "refuses with no run in the worktree, with exit 2" $ \world -> do
                ran <- state world ["next"]

                (ran.code, ran.err)
                    `shouldBe` (2, ["state next: no run in this worktree - no state init ran here", "fix: state init --notes /tmp/engineer-<owner>-<repo>-<slug>/"])

            it "names a hand-edited bad line and appends nothing after it" $ \world -> do
                _ <- drive world []
                run <- runOf world
                editLog world (<> ["{\"v\":3,broken"])
                before' <- logRows world

                for_ [("next", []), ("show", []), ("record", ["fuel.set", "max"])] $ \(sub, args) -> do
                    bad <- state world (sub : args)
                    (bad.code, map (fst . Text.breakOn " - ") bad.err)
                        `shouldBe` (2, ["state " <> sub <> ": run " <> run <> " event 2 is not read", "fix: state init --notes <a new dir> starts afresh"])
                after <- logRows world
                after `shouldBe` before'

            it "names the recovery for an older state's log: start fresh" $ \world -> do
                _ <- drive world []
                run <- runOf world
                editLog world (const ["{\"seq\":0,\"ts\":\"t\",\"head\":null,\"session\":null,\"event\":{\"type\":\"started\",\"notes\":\"n\",\"version\":2}}"])

                old <- state world ["next"]

                (old.code, old.err)
                    `shouldBe` (2, ["state next: run " <> run <> " event 1 is not read - log version 2, this state reads 4", "fix: state init --notes <a new dir> starts afresh"])

        describe "record" $ do
            it "refuses an event with no arrow: exit 2, a fix line, the refusal logged, and next warns" $ \world -> do
                _ <- drive world [Record ["fuel.set", "balanced"]]

                refused <- state world ["record", "ready.done", prUrl]

                (refused.code, refused.out, refused.err)
                    `shouldBe` (2, [], ["state record: ready.done - no such arrow out of gather", "fix: state record gather.enough | state record gather.interview | state record gather.research"])
                events <- loggedEvents world
                last events `shouldBe` "refused"
                warned <- succeeded =<< state world ["next"]
                take 3 warned
                    `shouldBe` ["RUN one option below", "refused: ready.done - no such arrow out of gather", "fix: state record gather.enough | state record gather.interview | state record gather.research"]

            it "fixes a refused event by the arrows this Fuel takes, never a skip it refuses" $ \world -> do
                _ <- drive world toSimplifyPr

                refused <- state world ["record", "await_ci.green"]

                (refused.code, refused.err)
                    `shouldBe` (2, ["state record: await_ci.green - no such arrow out of simplify_pr", "fix: state record simplify_pr.done"])

            it "appends the event and prints it with where the run is now" $ \world -> do
                _ <- startedRun world

                ran <- state world ["record", "fuel.set", "max"]

                (ran.code, ran.out, ran.err) `shouldBe` (0, ["recorded 2 fuel.set -> gather"], [])
                loggedEvents world `shouldReturn` ["started", "fuel.set"]

            it "refuses a surplus argument to an event with its own usage, not the whole help" $ \world -> do
                _ <- startedRun world

                ran <- state world ["record", "simplify_plan.done", "extra"]

                (ran.code, take 3 ran.err) `shouldBe` (2, ["Invalid argument `extra'", "", "Usage: state record simplify_plan.done"])

            it "names a usage error with exit 2, lists the events and writes nothing" $ \world -> do
                _ <- startedRun world

                ran <- state world ["record"]

                (ran.code, take 1 ran.err) `shouldBe` (2, ["Missing: EVENT"])
                ran.err `shouldSatisfy` any (Text.isPrefixOf "  fuel.set ")
                loggedEvents world `shouldReturn` ["started"]

        describe "handback" $ do
            it "records a role's hand-back from stdin" $ \world -> do
                _ <- drive world ([Record ["fuel.set", "balanced"]] <> gathered <> [Planned])

                ran <- stateIn world "READY\nDone.\n" ["handback", "researcher"]

                (ran.code, ran.err) `shouldBe` (0, [])
                recorded ran.out `shouldBe` ["simplify_plan.done -> confirm"]

            it "records a researcher's simplify report from stdin, which opens with no token" $ \world -> do
                _ <- drive world ([Record ["fuel.set", "balanced"]] <> gathered <> [Planned])

                ran <- stateIn world "# Plan (simplify proposal)\n## Goals\n" ["handback", "researcher"]

                (ran.code, ran.err) `shouldBe` (0, [])
                recorded ran.out `shouldBe` ["simplify_plan.done -> confirm"]

            it "advises a worker's BLOCKED for triage until the run asks it as its own" $ \world -> do
                _ <- drive world ([Record ["fuel.set", "balanced"]] <> init toImplement)
                _ <- succeeded =<< stateIn world "BLOCKED no access\n" ["handback", "implementer"]

                blocked <- succeeded =<< state world ["next"]
                asked : _ <- succeeded =<< state world ["ask", "--kind", "Pick", "--from", "implementer", "retry", "with", "a", "token?"]
                _ <- succeeded =<< state world ["rule", Text.drop (Text.length "asked ") asked, "--answer", "retry", "--why", "token granted", "--cost", "none"]
                ruled <- succeeded =<< state world ["next"]

                take 1 blocked `shouldBe` ["RUN state ask --kind <kind> --from implementer <question> - triage: BLOCKED no access"]
                ruled `shouldSatisfy` (not . any ("triage: BLOCKED no access" `Text.isInfixOf`))

            it "refuses a hand-back with no token on line 1, its fix piping it again with one" $ \world -> do
                _ <- drive world ([Record ["fuel.set", "balanced"]] <> init toImplement)

                ran <- stateIn world "Done, all green.\n" ["handback", "implementer"]

                ran.code `shouldBe` 2
                drop 1 ran.err `shouldBe` ["fix: state handback implementer < <the hand-back, a token added as line 1>"]

            it "refuses a Touches line with words after its areas, its fix piping it again with bare names" $ \world -> do
                _ <- drive world ([Record ["fuel.set", "balanced"]] <> init toImplement)
                untouched <- loggedEvents world

                ran <- stateIn world "READY\nTouches: interface (the parser)\n" ["handback", "implementer"]

                (ran.code, drop 1 ran.err) `shouldBe` (2, ["fix: state handback implementer < <the hand-back, its Touches: line bare names only, comma-separated: interface, data-model, auth or none>"])
                loggedEvents world `shouldReturn` untouched

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
                _ <- drive world [Record ["fuel.set", "balanced"], Override "ready", Record ["ready.done", prUrl]]

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
                                   , "fix: state override <fuel|gather|gather/researchers|gather/notes|gather/research|interview|plan|skip_simplify_plan|simplify_plan|confirm|draft|implement|skip_refactor|refactor|review|pick|fix|re_review|describe|simplify_pr|await_ci|fix_pr|ready> <why>"
                                   ]
                               )

            it "needs a state and why" $ \world -> do
                ran <- state world ["override", "review"]

                (ran.code, take 1 ran.err) `shouldBe` (2, ["Missing: <why>"])

        describe "void" $ do
            it "voids a line, the run replaying as if it was never logged" $ \world -> do
                _ <- drive world []
                _ <- succeeded =<< state world ["override", "review", "resume", "after", "a", "crash"]

                voided <- succeeded =<< state world ["void", "2", "overridden", "in", "error"]
                shown <- succeeded =<< state world ["show"]

                (voided, "step: review" `elem` shown) `shouldBe` (["recorded 3 voided -> fuel"], False)

            it "refuses a seq no line the run replays has, and the started line, which the run needs" $ \world -> do
                _ <- drive world []

                unknown <- state world ["void", "9", "why"]
                first <- state world ["void", "1", "why"]

                map (\ran -> (ran.code, ran.err)) [unknown, first]
                    `shouldBe` [ (2, ["state void: seq 9 - no line the run replays has it: none does, it is voided, or it is a void", "fix: state void <the seq of an event state dump prints> <why>"])
                               , (2, ["state void: the void of 1 - the log without it does not replay: the log - its first line is not started", "fix: state void <the later line that needs it> <why>, then this one"])
                               ]

        describe "move" $ do
            let sessionBindings = "/home/.local/state/state/bindings/s1"
            it "moves the run to another worktree, rebinding its agents there, its notes kept" $ \world -> do
                run <- startedRun world
                putFile world (sessionBindings </> "main") ("run " <> run <> " /notes /work\n")
                putFile world (sessionBindings </> "a1") "run ffff0000 /elsewhere /work\n"
                addWorktree world "/target"

                moved <- succeeded =<< state world ["move", "/target"]
                old <- state world ["show"]
                atWorktree world "/target"
                shown <- succeeded =<< state world ["show"]
                rebound <- traverse (fileBytes world . (sessionBindings </>)) ["main", "a1"]

                (moved, old.code, take 1 shown) `shouldBe` (["moved " <> run <> " to /target"], 2, ["run: " <> run <> " (engineer)"])
                rebound
                    `shouldBe` [Just (encodeUtf8 ("run " <> run <> " /notes /target\n")), Just "run ffff0000 /elsewhere /work\n"]

            it "refuses a target in no worktree, this worktree, and one holding an unfinished run" $ \world -> do
                run <- startedRun world
                addWorktree world "/target"
                atWorktree world "/target"
                other <- startedIn world ["--notes", "/other"]
                atWorktree world "/work"

                refused <- traverse (\target -> state world ["move", target]) ["/nowhere", "/work", "/target"]
                shown <- succeeded =<< state world ["show"]

                map (\ran -> (ran.code, take 1 ran.err)) refused
                    `shouldBe` [ (2, ["state move: /nowhere is in no git worktree - git finds none there"])
                               , (2, ["state move: /work - it is this worktree, which holds the run already"])
                               , (2, ["state move: /target - its worktree holds unfinished run " <> other <> " in /other"])
                               ]
                take 1 shown `shouldBe` ["run: " <> run <> " (engineer)"]

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

        it "hands a --child run's forwarded question back to its caller, never to the user" $ \world -> do
            _ <- startedIn world ["--child"]

            asked <- succeeded =<< state world ["ask", "--kind", "Design", "which", "store?"]
            again <- succeeded =<< state world ["next"]

            map (take 1) [drop 1 asked, again] `shouldSatisfy` all (all ("HANDBACK NEEDS_DECISION Design " `Text.isPrefixOf`))
            filter (== "ASK user") (asked <> again) `shouldBe` []

        it "tells a --child run resumed with its caller's answer how to record it, as no parent log does" $ \world -> do
            _ <- startedIn world ["--child"]
            asked : _ <- succeeded =<< state world ["ask", "--kind", "Design", "which", "store?"]
            let qid = Text.drop (Text.length "asked ") asked

            waiting <- succeeded =<< state world ["next"]
            _ <- succeeded =<< state world ["answer", qid, "postgres"]
            answered <- succeeded =<< state world ["next"]

            waiting `shouldContain` ["  resumed with the answer: state answer " <> qid <> " <answer>"]
            filter ("HANDBACK " `Text.isPrefixOf`) (take 1 answered) `shouldBe` []

        it "shows a forwarded question with the answer that came down for it" $ \world -> do
            _ <- startedRun world
            [asked, _] <- succeeded =<< state world ["ask", "--kind", "Design", "which", "store?"]
            let qid = Text.drop (Text.length "asked ") asked
            _ <- succeeded =<< state world ["answer", qid, "postgres"]

            shown <- succeeded =<< state world ["show"]

            shown `shouldContain` ["answered:", "  " <> qid <> " Design: which store? - postgres"]

        it "refuses the same open question from the same asker, naming the open one" $ \world -> do
            _ <- startedRun world
            [asked, _] <- succeeded =<< state world ["ask", "--kind", "Design", "which", "store?"]
            let qid = Text.drop (Text.length "asked ") asked

            again <- state world ["ask", "--kind", "Design", "which", "store?"]
            pending <- succeeded =<< state world ["pending"]

            (again.code, again.err) `shouldBe` (2, ["state ask: the question - it is open already as " <> qid, "fix: state next"])
            pending `shouldBe` [qid <> " Design forwarded from this run: which store?"]

        describe "the 10x" $ do
            it "spawns the first task, the second waiting on it" $ \world -> do
                _ <- tenXAtFanOut world

                advised <- succeeded =<< state world ["next"]

                take 1 advised `shouldBe` ["SPAWN engineer --task t1 background: yes"]

            it "spawns a --child 10x's tasks in the foreground, as a subagent cannot wait on the background" $ \world -> do
                _ <- tenXAtFanOutBy world ["--child"] [plainTask "t1" []]

                advised <- succeeded =<< state world ["next"]

                take 1 advised `shouldBe` ["SPAWN engineer --task t1 background: no"]

            it "spawns a task's child as the role leading its task's flow" $ \world -> do
                _ <- tenXAtFanOutOf world [(plainTask "t1" []) {flow = TenXFlow}]

                advised <- succeeded =<< state world ["next"]

                take 1 advised `shouldBe` ["SPAWN 10x --task t1 background: yes"]

            it "logs a child's spawn in its parent's log once, a retried init joining the same run" $ \world -> do
                parent <- tenXAtFanOut world

                child <- childRun world parent "/child" "t1"
                again <- succeeded =<< state world ["init", "--notes", "/child", "--parent", parent, "--task", "t1"]

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

                refused <- state world ["init", "--notes", "/child", "--flow", "10x", "--parent", parent, "--task", "t1"]

                (refused.code, refused.err)
                    `shouldBe` (2, ["state init: --flow 10x - task t1 runs the engineer flow", "fix: state brief engineer --task t1, in the parent's worktree, prints the init line"])
                filter (== "spawned") <$> loggedEvents world `shouldReturn` []

            it "starts a 10x child for a task whose flow is 10x, --flow named or not" $ \world -> do
                parent <- tenXAtFanOutOf world [(plainTask "t1" []) {flow = TenXFlow}, (plainTask "t2" []) {flow = TenXFlow}]
                atWorktree world childWorktree
                named <- succeeded =<< state world ["init", "--notes", "/child", "--flow", "10x", "--parent", parent, "--task", "t1"]
                namedShown <- succeeded =<< state world ["show"]
                atWorktree world "/other-work"
                _ <- succeeded =<< state world ["init", "--notes", "/other", "--parent", parent, "--task", "t2"]
                unnamedShown <- succeeded =<< state world ["show"]

                map (Text.takeWhile (/= ' ')) named `shouldBe` ["started", "run"]
                map (take 1) [namedShown, unnamedShown] `shouldSatisfy` all (all (" (10x)" `Text.isSuffixOf`))

            it "refuses an engineer child for a task whose flow is 10x" $ \world -> do
                parent <- tenXAtFanOutOf world [(plainTask "t1" []) {flow = TenXFlow}]
                atWorktree world childWorktree

                refused <- state world ["init", "--notes", "/child", "--flow", "engineer", "--parent", parent, "--task", "t1"]

                (refused.code, refused.err)
                    `shouldBe` (2, ["state init: --flow engineer - task t1 runs the 10x flow", "fix: state brief 10x --task t1, in the parent's worktree, prints the init line"])

            it "starts a child at its task's Fuel, so its first next is the step, in the foreground" $ \world -> do
                parent <- tenXAtFanOutOf world [(plainTask "t1" []) {fuel = Max}]
                _ <- childRun world parent "/child" "t1"

                advised <- succeeded =<< state world ["next"]

                take 1 advised `shouldBe` ["RUN one option below"]
                advised `shouldSatisfy` any ("which spawns a researcher in the foreground" `Text.isInfixOf`)
                -- Max's researcher budget: Balanced, the default, caps it.
                filter ("Researchers: " `Text.isInfixOf`) advised `shouldBe` ["  Researchers: 0 used, one per group"]

            it "starts a child whose --flow names its parent's fan-out's" $ \world -> do
                parent <- tenXAtFanOut world
                atWorktree world childWorktree

                accepted <- state world ["init", "--notes", "/child", "--flow", "engineer", "--parent", parent, "--task", "t1"]

                (accepted.code, map (Text.takeWhile (/= ' ')) accepted.out) `shouldBe` (0, ["started", "run"])

            it "refuses a child for a task the parent's breakdown lacks, logging no spawn" $ \world -> do
                parent <- tenXAtFanOut world
                atWorktree world childWorktree

                refused <- state world ["init", "--notes", "/child", "--parent", parent, "--task", "t9"]

                (refused.code, refused.err)
                    `shouldBe` (2, ["state init: --task t9 - the parent's breakdown has no such task", "fix: state brief engineer, in the parent's worktree, prints the init line"])
                filter (== "spawned") <$> loggedEvents world `shouldReturn` []

            it "refuses a child its parent cannot take, leaving its worktree no run" $ \world -> do
                parent <- startedRun world
                atWorktree world childWorktree

                ran <- state world ["init", "--notes", "/child", "--parent", parent, "--task", "t1"]
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
                _ <- succeeded =<< state world ["record", "gather.research"]

                again <- succeeded =<< state world ["next"]

                take 1 again `shouldSatisfy` all ("HANDBACK NEEDS_DECISION Design " `Text.isPrefixOf`)
                again `shouldSatisfy` (not . any ("parent: " `Text.isPrefixOf`))
                loggedEvents world `shouldReturn` once

            for_ [(ChildConfirms, ["plan.done -> skip_simplify_plan", "skip_simplify_plan.run -> simplify_plan"]), (ParentDecided, ["plan.done -> skip_simplify_plan", "skip_simplify_plan.skip -> confirm", "confirm.confirmed -> draft"])] $ \(plan, transcript) ->
                it ("passes a child's plan per its task's plan call, asking its parent nothing: " <> show plan) $ \world -> do
                    parent <- tenXAtFanOutOf world [(plainTask "t1" []) {plan}]
                    _ <- childRun world parent "/child" "t1"
                    _ <- succeeded =<< state world ["record", "gather.enough"]
                    _ <- succeeded =<< state world ["record", "gather/notes.done"]
                    putFile world "/child/plan.md" "the plan"
                    planned <- succeeded =<< state world ["record", "plan.done", "/child/plan.md"]
                    advised <- succeeded =<< state world ["next"]

                    recorded (planned <> advised) `shouldBe` transcript
                    filter (== "asked") <$> loggedEvents world `shouldReturn` []

            it "drops a parked task's forwarded question from pending and next" $ \world -> do
                parent <- tenXAtFanOut world
                _ <- childRun world parent "/child" "t1"
                _ <- succeeded =<< state world ["ask", "--kind", "Design", "which", "store?"]
                atWorktree world "/work"
                asked <- succeeded =<< state world ["pending"]

                _ <- succeeded =<< state world ["record", "task", "t1", "parked", "out", "of", "scope"]
                pending <- succeeded =<< state world ["pending"]
                advised <- succeeded =<< state world ["next"]

                asked `shouldSatisfy` any ("which store?" `Text.isSuffixOf`)
                pending `shouldBe` []
                advised `shouldSatisfy` (not . any ("which store?" `Text.isInfixOf`))

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
                    broken = "{broken"
                climbed world qid
                editLogIn world grandNotes (<> [broken])

                failed <- succeeded =<< state world ["answer", qid, "it's postgres"]
                editLogIn world grandNotes (filter (/= broken))
                retried <- succeeded =<< state world ["answer", qid, "it's postgres"]

                drop 1 failed `shouldSatisfy` \case
                    [why, fix] -> ("child " <> grand <> ": ") `Text.isPrefixOf` why && fix == "fix: state answer " <> qid <> " 'it'\\''s postgres' --by " <> mid <> ", in " <> Text.pack grandWorktree
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
                               , "state init --notes <dir> --parent " <> run <> " --task t2"
                               ]

            it "briefs a 10x task's init line with its flow, whichever lead role asks" $ \world -> do
                run <- tenXAtFanOutOf world [(plainTask "t1" []) {flow = TenXFlow}]

                briefs <- traverse (\role -> succeeded =<< state world ["brief", role, "--task", "t1"]) ["engineer", "10x"]

                map (drop 9) briefs
                    `shouldBe` replicate 2 ["state init --notes <dir> --flow 10x --parent " <> run <> " --task t1"]

            it "briefs an engineer to init in its task's worktree and its repo's notes dir" $ \world -> do
                run <- tenXAtFanOutOf world [(plainTask "t1" []) {branch = Branch "feat/x", repo = Just (Repo "o" "r"), worktree = shellPath "/wt/t1"}]

                brief <- succeeded =<< state world ["brief", "engineer", "--task", "t1"]

                drop 9 brief
                    `shouldBe` ["cd /wt/t1 && state init --notes /tmp/engineer-o-r-feat-x/ --parent " <> run <> " --task t1"]

            it "briefs an engineer a notes dir whose branch slug holds nothing a shell reads" $ \world -> do
                run <- tenXAtFanOutOf world [(plainTask "t1" []) {branch = Branch "feat/x;rm -rf $(y)`z`|w", repo = Just (Repo "o" "r")}]

                brief <- succeeded =<< state world ["brief", "engineer", "--task", "t1"]

                drop 9 brief
                    `shouldBe` ["state init --notes /tmp/engineer-o-r-feat-x-rm--rf---y--z--w/ --parent " <> run <> " --task t1"]

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

            it "refuses a section the role does not run, naming its sections" $ \world -> do
                _ <- drive world []

                refused <- state world ["brief", "researcher", "--section", "implement"]

                (refused.code, refused.err)
                    `shouldBe` (2, ["state brief: section implement - the role's sections are research, simplify_plan", "fix: state brief researcher --section <step>"])

        describe "render" $ do
            it "prints a block of the flow without a run" $ \world -> do
                ran <- state world ["render", "stop-rule"]

                (ran.code, ran.out, ran.err) `shouldBe` (0, Text.lines Render.stopRule, [])

            it "prints each flow's init line, as the hooks name it" $ \world -> do
                ran <- traverse (\flow -> state world ["render", "init", "--flow", flow]) ["engineer", "10x"]

                [(r.code, r.out) | r <- ran] `shouldBe` [(0, ["state init --notes /tmp/engineer-<owner>-<repo>-<slug>/"]), (0, ["state init --notes \"$PWD\" --flow 10x"])]

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
    mid <- startedIn world ["--notes", Text.pack midNotes, "--parent", top, "--task", "t1"]
    putFile world (midNotes </> "tasks.json") (breakdownJson [plainTask "t1" []])
    _ <- succeeded =<< state world ["override", "breakdown", "the", "plan", "is", "agreed"]
    _ <- succeeded =<< state world ["record", "breakdown.done", "--tasks", Text.pack (midNotes </> "tasks.json")]
    atWorktree world grandWorktree
    grand <- startedIn world ["--notes", Text.pack grandNotes, "--parent", mid, "--task", "t1"]
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
answersIn world = traverse (fmap (length . filter (== "answered")) . loggedEventsIn world) [notes, midNotes, grandNotes]

midNotes, grandNotes, midWorktree, grandWorktree :: FilePath
midNotes = "/mid"
grandNotes = "/grand"
midWorktree = "/mid-work"
grandWorktree = "/grand-work"

-- | A Balanced run to its first Simplify of the PR.
toSimplifyPr :: [Act]
toSimplifyPr =
    Record ["fuel.set", "balanced"]
        : toImplement
            <> [Handback "review-lead" reviewed, Record ["pick.final"], Handback "fixer" ready]

balancedPath :: [Act]
balancedPath = toSimplifyPr <> [Handback "fixer" simplified, Record ["await_ci.green"], Record ["ready.done", prUrl]]

balancedTranscript :: [Text]
balancedTranscript =
    [ "fuel.set -> gather"
    , "gather.research -> gather/research"
    , "gather/research.spawned -> gather"
    , "gather/research.handed_back -> gather"
    , "gather.enough -> gather/notes"
    , "gather/notes.done -> plan"
    , "plan.done -> skip_simplify_plan"
    , "skip_simplify_plan.run -> simplify_plan"
    , "simplify_plan.done -> confirm"
    , "confirm.confirmed -> draft"
    , "draft.done -> implement"
    , "implement.done -> skip_refactor"
    , "skip_refactor.skip -> review"
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
    Record ["fuel.set", "low"]
        : gathered
            <> [ Planned
               , Record ["skip_simplify_plan.skip"]
               , Record ["confirm.confirmed"]
               , OpenPr
               , Commit
               , Handback "implementer" ready
               , Record ["skip_refactor.skip"]
               , Handback "review-lead" reviewed
               , Record ["pick.final"]
               , Handback "fixer" ready
               , Handback "fixer" simplified
               , Record ["await_ci.green"]
               , Record ["ready.done", prUrl]
               ]

trivialTranscript :: [Text]
trivialTranscript =
    [ "fuel.set -> gather"
    , "gather.enough -> gather/notes"
    , "gather/notes.done -> plan"
    , "plan.done -> skip_simplify_plan"
    , "skip_simplify_plan.skip -> confirm"
    , "confirm.confirmed -> draft"
    , "draft.done -> implement"
    , "implement.done -> skip_refactor"
    , "skip_refactor.skip -> review"
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
    [ "  Low: skip it when the task is trivial: state record skip_simplify_plan.skip"
    , "  Low: skip it when the task is trivial: state record skip_refactor.skip"
    ]

-- | 'toImplement' with the proposal's run recorded by the agent, as at Low, where the kernel leaves it the skip.
ranProposal :: [Act]
ranProposal = planned <> [Record ["skip_simplify_plan.run"]] <> proposed
  where
    (planned, proposed) = splitAt 6 toImplement

-- | Balanced, moved to the review by override.
atReview :: [Act]
atReview = [Record ["fuel.set", "balanced"], Override "review"]

-- | A review back with its rows, and the lead's picks: a loop on this row.
reviewRound :: Text -> [Text] -> [Act]
reviewRound label verdicts = [Commit, Handback "review-lead" reviewed, Record (["pick.loop", "--row", label] <> verdicts)]
