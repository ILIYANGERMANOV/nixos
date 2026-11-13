{- | @state@'s commands over the test doubles: what each prints, its exit and
the log it writes. The e2e specs prove the same over a real repo and binary.
-}
module State.Shell.MainSpec (spec) where

import Data.Foldable (for_)
import Data.IORef (modifyIORef', readIORef)
import Data.List (isSuffixOf)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)
import State.Advice (PrView (..), Readiness (..))
import State.Cli (help)
import State.Event (Envelope (..), SessionId (..))
import State.Render qualified as Render
import State.RunGen (loadSteps)
import State.Shell.World
import System.FilePath ((</>))
import Test.Hspec (Spec, before, describe, it, runIO, shouldBe, shouldContain, shouldReturn, shouldSatisfy)

spec :: Spec
spec = describe "state over the doubles" $ do
    table <- runIO loadSteps
    before newWorld $ do
        describe "init" $ do
            it "starts a run with an id from the entropy, and its log" $ \world -> do
                ran <- state world ["init", "--notes", "/notes"]

                (ran.code, ran.out, ran.err) `shouldBe` (0, ["started 00010203"], [])
                loggedEvents world `shouldReturn` ["started"]

            it "starts a run once per notes dir, and refuses one there after it stopped" $ \world -> do
                run <- startedRun world
                again <- startedRun world
                _ <- succeeded =<< state world ["stop", "replan", "the", "plan", "is", "wrong"]

                refused <- state world ["init", "--notes", "/notes"]

                again `shouldBe` run
                (refused.code, refused.err)
                    `shouldBe` (2, ["state init: --notes /notes - its run " <> run <> " stopped: replan the plan is wrong", "fix: state init --notes <a new dir>"])

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
            it "runs the engineer flow at Balanced Normal from init to ready" $ \world -> do
                transcript <- drive world balancedPath

                done <- succeeded =<< state world ["next"]

                transcript `shouldBe` balancedTranscript
                take 4 done
                    `shouldBe` ["DONE " <> prUrl, "  mode: Balanced Normal", "  changed lines: 1", "  PR: " <> prUrl <> " (draft)"]

            it "logs the steps POC Trivial skips, reviews once and skips ready" $ \world -> do
                transcript <- drive world trivialPath

                done <- succeeded =<< state world ["next"]

                transcript `shouldBe` trivialTranscript
                take 1 done `shouldBe` ["DONE " <> prUrl]

            it "prints each record it advises with its arguments" $ \world -> do
                _ <- drive world [Record ["quality", "Balanced"], Record ["size", "Normal"], Record ["research.done", "2"], Record ["interview.enough"]]

                advice <- succeeded =<< state world ["next"]

                take 1 advice `shouldBe` ["RUN state record plan.done <path>"]

            it "goes on without GitHub when gh cannot be read, saying why" $ \world -> do
                _ <- startedRun world
                modifyIORef' world (\w -> w {pr = PrViewTimedOut 10})

                advice <- succeeded =<< state world ["next"]

                advice `shouldContain` ["  PR sync skipped - gh pr view timed out after 10s"]

            it "says the changed lines are unknown when origin lacks the PR's base" $ \world -> do
                _ <- drive world [Record ["quality", "Balanced"], Record ["size", "Normal"]]
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

                for_ [("next", []), ("show", []), ("record", ["quality", "Max"])] $ \(sub, args) -> do
                    bad <- state world (sub : args)
                    (bad.code, map (fst . Text.breakOn " - ") bad.err)
                        `shouldBe` (2, ["state " <> sub <> ": /notes/events.jsonl line 2 is not read", "fix: repair or move /notes/events.jsonl"])
                after <- logBytes world
                after `shouldBe` before'

        describe "record" $ do
            it "refuses an event with no arrow: exit 2, a fix line, the refusal logged, and next warns" $ \world -> do
                _ <- drive world [Record ["quality", "Balanced"], Record ["size", "Normal"]]

                refused <- state world ["record", "ready.done", prUrl]

                (refused.code, refused.out, refused.err)
                    `shouldBe` (2, [], ["state record: ready.done - no such arrow out of research", "fix: state record research.done <n>"])
                events <- loggedEvents world
                last events `shouldBe` "refused"
                warned <- succeeded =<< state world ["next"]
                take 3 warned
                    `shouldBe` ["SPAWN researcher background: yes", "refused: ready.done - no such arrow out of research", "fix: state record research.done <n>"]

            it "fixes a refused event by the arrows this mode takes, never a skip it refuses" $ \world -> do
                _ <- drive world toSimplifyPr

                refused <- state world ["record", "await_ci.green"]

                (refused.code, refused.err)
                    `shouldBe` (2, ["state record: await_ci.green - no such arrow out of simplify_pr", "fix: state record simplify_pr.done"])

            it "appends the event and prints it with where the run is now" $ \world -> do
                _ <- startedRun world

                ran <- state world ["record", "quality", "Max"]

                (ran.code, ran.out, ran.err) `shouldBe` (0, ["recorded 2 quality -> research"], [])
                loggedEvents world `shouldReturn` ["started", "quality"]

            it "names a usage error with exit 2 and writes nothing" $ \world -> do
                _ <- startedRun world

                ran <- state world ["record"]

                (ran.code, ran.err) `shouldBe` (2, ["state record: no event - record names one event", "fix: state help"])
                loggedEvents world `shouldReturn` ["started"]

        describe "handback" $ do
            it "records a role's hand-back from stdin" $ \world -> do
                _ <- drive world [Record ["quality", "Balanced"], Record ["size", "Normal"], Record ["research.done", "2"], Record ["interview.enough"], Record ["plan.done", "/notes/plan.md"]]

                ran <- stateIn world "READY\nDone.\n" ["handback", "researcher"]

                (ran.code, ran.err) `shouldBe` (0, [])
                recorded ran.out `shouldBe` ["simplify_plan.done -> alternative"]

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
                                   , "fix: state override <research|interview|plan|simplify_plan|alternative|confirm|draft|implement|refactor|review|pick|fix|describe|simplify_pr|await_ci|fix_pr|ready> <why>"
                                   ]
                               )

            it "needs a state and why" $ \world -> do
                ran <- state world ["override", "review"]

                (ran.code, ran.err) `shouldBe` (2, ["state override: override needs a state and why - state override <state> <why>", "fix: state help"])

        describe "the review loop" $ do
            it "asks Stuck when rounds 1 and 2 pick the same row" $ \world -> do
                _ <- drive world (atReview <> reviewRound "R1" [] <> [Handback "fixer" ready] <> reviewRound "R1" [])

                advice <- succeeded =<< state world ["next"]

                take 1 advice `shouldBe` ["ASK Stuck the review loop repeats R1: go on, change course, or stop?"]

            it "gives a Not met at the fuel one more round, then exits" $ \world -> do
                let rounds = concat [reviewRound label [] <> [Handback "fixer" ready] | label <- ["R1", "R2", "R3"]]
                _ <- drive world (atReview <> rounds <> reviewRound "R4" ["--verdict", "docs=not-met"] <> [Handback "fixer" ready, Handback "review-lead" reviewed])

                advice <- succeeded =<< state world ["next"]
                refused <- state world ["record", "pick.loop", "--row", "R5", "--verdict", "docs=not-met"]
                exited <- succeeded =<< state world ["record", "pick.final"]

                take 1 advice `shouldSatisfy` all ("- no review round is left" `Text.isSuffixOf`)
                (refused.code, refused.err)
                    `shouldBe` (2, ["state record: another review round - the loop ran its 4 rounds", "fix: state record pick.final [--row <label>]... [--verdict <requirement>=<met|not-met|unverified>]... | state stop fuel <why>"])
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

        describe "the 10x" $ do
            it "spawns the first task, the second waiting on it" $ \world -> do
                _ <- tenXAtFanOut world

                advised <- succeeded =<< state world ["next"]

                take 1 advised `shouldBe` ["SPAWN engineer --task t1 background: yes"]

            it "logs a child's spawn in its parent's log once, a retried init joining the same run" $ \world -> do
                parent <- tenXAtFanOut world

                child <- childRun world parent "/child" "t1"
                again <- childRun world parent "/child" "t1"

                again `shouldBe` child
                filter (== "spawned") <$> loggedEvents world `shouldReturn` ["spawned"]

            it "refuses a child its parent cannot take, keeping the worktree's run" $ \world -> do
                parent <- startedRun world

                ran <- state world ["init", "--notes", "/child", "--parent", parent, "--parent-log", Text.pack eventsPath, "--task", "t1"]
                shown <- succeeded =<< state world ["show"]

                ran.code `shouldBe` 2
                take 1 shown `shouldBe` ["run: " <> parent <> " (engineer)"]

            it "records a child's hand-back that names its run, and refuses one that does not" $ \world -> do
                parent <- tenXAtFanOut world
                child <- childRun world parent "/child" "t1"
                _ <- succeeded =<< state world ["init", "--notes", Text.pack notes]

                unnamed <- stateIn world "READY https://pr/1\n" ["handback", "engineer"]
                named <- stateIn world (encodeUtf8 ("READY https://pr/1\nRun: " <> child <> "\n")) ["handback", "engineer"]

                unnamed.code `shouldBe` 2
                (named.code, recorded named.out) `shouldBe` (0, ["handed_back -> engineers"])

            it "shows each task, its PR and what is held" $ \world -> do
                _ <- tenXAtFanOut world
                for_ [["task", "t1", "review", prUrl], ["held", "t2", "https://github.com/o/r/issues/9"]] $ \argv -> succeeded =<< state world ("record" : argv)

                shown <- succeeded =<< state world ["show"]

                shown `shouldContain` ["task t1: not started, PR review " <> prUrl <> ", tries 0", "task t2: not started, tries 0"]
                shown `shouldContain` ["held:", "  t2 https://github.com/o/r/issues/9"]

            it "briefs an engineer with its task's fields, then its init line" $ \world -> do
                run <- tenXAtFanOut world

                brief <- succeeded =<< state world ["brief", "engineer", "--task", "t2"]

                brief
                    `shouldBe` [ "Task: t2"
                               , "Quality: Balanced"
                               , "Size: Normal"
                               , "Base: main"
                               , "Branch: t2"
                               , "Depends on: t1"
                               , "QA: no"
                               , "Heavy: yes"
                               , "Security-sensitive: none"
                               , ""
                               , "state init --notes <dir> --parent " <> run <> " --parent-log " <> Text.pack eventsPath <> " --task t2"
                               ]

            it "refuses to brief an engineer for a task the breakdown lacks" $ \world -> do
                _ <- tenXAtFanOut world

                ran <- state world ["brief", "engineer", "--task", "t9"]

                ran.code `shouldBe` 2

        describe "brief" $ do
            it "gives a refactorer its step's entry and the stop rule" $ \world -> do
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
            it "prints help with no command" $ \world -> do
                ran <- state world []

                (ran.code, ran.out, ran.err) `shouldBe` (0, Text.lines (help table), [])

            it "refuses a command it does not know, with exit 2" $ \world -> do
                ran <- state world ["nowhere"]

                ran.code `shouldBe` 2
                take 1 ran.err `shouldSatisfy` all ("state nowhere: " `Text.isPrefixOf`)

            it "is an outage, exit 1, without the step table STATE_STEPS names" $ \world -> do
                modifyIORef' world (\w -> w {env = Map.delete "STATE_STEPS" w.env})

                ran <- state world ["next"]

                (ran.code, ran.err) `shouldBe` (1, ["state steps: STATE_STEPS is not set - it names the flows' step table", "fix: run the installed state, which sets it"])

-- | A Balanced Normal run to its first Simplify of the PR.
toSimplifyPr :: [Act]
toSimplifyPr =
    [Record ["quality", "Balanced"], Record ["size", "Normal"]]
        <> toImplement
        <> [Handback "review-lead" reviewed, Record ["pick.final"], Handback "fixer" ready]

balancedPath :: [Act]
balancedPath = toSimplifyPr <> [Handback "fixer" simplified, Record ["await_ci.green"], Record ["ready.done", prUrl]]

balancedTranscript :: [Text]
balancedTranscript =
    [ "quality -> research"
    , "size -> research"
    , "research.done -> interview"
    , "interview.enough -> plan"
    , "plan.done -> simplify_plan"
    , "simplify_plan.done -> alternative"
    , "alternative.done -> confirm"
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

-- | POC Trivial: no researcher, proposal or refactor runs, so no hand-back of theirs.
trivialPath :: [Act]
trivialPath =
    [ Record ["quality", "POC"]
    , Record ["size", "Trivial"]
    , Record ["interview.enough"]
    , Record ["plan.done", Text.pack (notes </> "plan.md")]
    , Record ["confirm.confirmed"]
    , OpenPr
    , Commit
    , Handback "implementer" ready
    , Handback "review-lead" reviewed
    , Refused ["pick.loop", "--row", "R1"]
    , Record ["pick.final"]
    , Handback "fixer" ready
    , Handback "fixer" simplified
    , Record ["await_ci.green"]
    ]

trivialTranscript :: [Text]
trivialTranscript =
    [ "quality -> research"
    , "size -> research"
    , "research.skipped -> interview"
    , "interview.enough -> plan"
    , "plan.done -> simplify_plan"
    , "simplify_plan.skipped -> confirm"
    , "alternative.skipped -> confirm"
    , "confirm.confirmed -> draft"
    , "draft.done -> implement"
    , "implement.done -> refactor"
    , "refactor.skipped -> review"
    , "review.rows -> pick"
    , "pick.final -> describe"
    , "describe.done -> simplify_pr"
    , "simplify_pr.done -> await_ci"
    , "await_ci.green -> ready"
    , "ready.skipped -> out"
    ]

-- | Balanced Normal, moved to the review by override.
atReview :: [Act]
atReview = [Record ["quality", "Balanced"], Record ["size", "Normal"], Override "review"]

-- | A review back with its rows, and the lead's picks: a loop on this row.
reviewRound :: Text -> [Text] -> [Act]
reviewRound label verdicts = [Commit, Handback "review-lead" reviewed, Record (["pick.loop", "--row", label] <> verdicts)]
