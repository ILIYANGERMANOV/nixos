{- | The e2e scenarios of #360 on the built @state@ binary (@$STATE_BIN@): each
runs in a temp worktree on branch @feat@, whose base @main@ is pushed to a bare
origin, with a scripted @gh@ first on PATH. Scenario 6 drives @state-hook@,
slice C's.
-}
module State.E2ESpec (spec) where

import Control.Monad (void, (<=<))
import Data.Aeson (Value (..), encode, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Pair)
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.Either (rights)
import Data.Foldable (for_)
import Data.List (isSuffixOf)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import State.Category.Fuel (Fuel (Low))
import State.Run.Codec (decodeLine, eventType)
import State.Run.Event (Envelope (..), FlowName (TenXFlow), Task (..))
import State.Run.RunGen (breakdownJson, plainTask, roundTask, taskFileJson)
import System.Directory (createDirectory, findExecutable, getPermissions, setOwnerExecutable, setPermissions)
import System.Environment (getEnv, getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import Test.Hspec (Spec, around, describe, expectationFailure, it, runIO, shouldBe, shouldContain, shouldSatisfy)

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
                `shouldBe` ["DONE " <> prUrl, "  at the end: the flow is done", "  fuel: balanced", "  changed lines: 1", "  PR: " <> prUrl <> " (draft)"]

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
            _ <- drive bin repo [Record ["fuel", "balanced"]]
            refused <- state bin repo ["record", "ready.done", prUrlString]
            (refused.code, refused.err)
                `shouldBe` (2, ["state record: ready.done - no such arrow out of gather", "fix: state record research.spawned | state record gather.enough"])
            warned <- succeeded =<< state bin repo ["next"]
            take 3 warned
                `shouldBe` ["RUN one option below", "refused: ready.done - no such arrow out of gather", "fix: state record research.spawned | state record gather.enough"]
            _ <- succeeded =<< state bin repo ["record", "gather.enough"]
            moved <- succeeded =<< state bin repo ["next"]
            moved `shouldSatisfy` (not . mentions "refused:")

        it "refuses an unknown event, listing the gather's events and fixing it by its step's, unlogged" $ \repo -> do
            _ <- drive bin repo [Record ["fuel", "balanced"]]
            before <- logLines repo
            refused <- state bin repo ["record", "gather.bogus"]
            after <- logLines repo
            (refused.code, refused.err, after - before)
                `shouldBe` ( 2
                           ,
                               [ "state record: no event gather.bogus - at gather the run takes research.spawned, research.handed_back, gather.enough, extend"
                               , "fix: state record gather.enough"
                               ]
                           , 0
                           )

        it "refuses an unknown event with no run, listing every event and fixing it by the help" $ \repo -> do
            refused <- state bin repo ["record", "bogus"]
            (refused.code, map (Text.isPrefixOf "state record: no event bogus - the events are fuel, research.spawned, ") (take 1 refused.err), drop 1 refused.err)
                `shouldBe` (2, [True], ["fix: state help"])

        it "takes a question's kind in any case" $ \repo -> do
            _ <- startedRun bin repo
            asked <- traverse (\kind -> state bin repo ["ask", "--kind", kind, "which", "store?"]) ["design", "DESIGN", "Design"]
            map (.code) asked `shouldBe` [0, 0, 0]

        it "refuses a ruling's unquoted words, telling to quote them" $ \repo -> do
            (w1, qid) <- childQuestion bin repo
            unquoted <- state bin w1 ["rule", Text.unpack qid, "--answer", "use", "Y", "--why", "it", "is", "simpler", "--cost", "none"]
            (unquoted.code, unquoted.err)
                `shouldBe` (2, ["state rule: --answer, --why and --cost - each takes one word: quote a longer one", "fix: state rule " <> qid <> " --answer \"<a>\" --why \"<w>\" --cost \"<c>\""])

        it "takes a ruling's quoted words as one answer, why and cost" $ \repo -> do
            (w1, qid) <- childQuestion bin repo
            _ <- succeeded =<< state bin w1 ["rule", Text.unpack qid, "--answer", "use Y", "--why", "it is simpler", "--cost", "none"]
            shown <- succeeded =<< state bin w1 ["show"]
            shown `shouldContain` ["  Ruling " <> qid <> " Pick: use Y - it is simpler - none"]

        it "refuses a question id that is not open, listing the open ones" $ \repo -> do
            run <- startedRun bin repo
            qid <- askedQid bin repo "Design" ["which", "store?"]
            refused <- traverse (\raw -> state bin repo ["forward", raw]) ["q1", Text.unpack run <> ":99"]
            [(ran.code, drop 1 (Text.splitOn " - " (Text.concat (take 1 ran.err))), drop 1 ran.err) | ran <- refused]
                `shouldBe` replicate 2 (2, ["it is not open; open: " <> qid], ["fix: state pending"])

        -- A written plan is taken on every path the transcripts below drive.
        it "refuses a plan.done whose plan is not written" $ \repo -> do
            _ <- drive bin repo [Record ["fuel", "balanced"], Record ["gather.enough"]]
            missing <- state bin repo ["record", "plan.done", "/no/such"]
            (missing.code, missing.err) `shouldBe` (2, ["state record: /no/such - no such file", "fix: write it first"])

        it "closes a researcher's child on its report, which has no token, so the gather ends" $ \repo -> do
            _ <- drive bin repo [Record ["fuel", "balanced"], Spawn "researcher"]
            early <- state bin repo ["record", "gather.enough"]
            back <- succeeded =<< hook hookBin repo "handback" (reportedBack repo "researcher" researched)
            enough <- succeeded =<< state bin repo ["record", "gather.enough"]
            (early.code, back, recorded enough) `shouldSatisfy` \case
                (2, [reply], ["gather.enough -> plan"]) -> "research.handed_back -> gather" `Text.isInfixOf` reply
                _ -> False

        it "prints each record it advises with its arguments" $ \repo -> do
            _ <- drive bin repo [Record ["fuel", "balanced"], Record ["gather.enough"]]
            advice <- succeeded =<< state bin repo ["next"]
            take 1 advice `shouldBe` ["RUN state record plan.done <path>"]

        it "prints the run's id, notes dir and worktree top, one line a hook parses" $ \repo -> do
            top <- Text.strip . Text.pack <$> gitOut repo ["rev-parse", "--show-toplevel"]
            started@[said, _] <- succeeded =<< state bin repo ["init", "--notes", repo.notes <> "/"]
            let run = Text.drop (Text.length "started ") said
            resumed <- succeeded =<< state bin repo ["init", "--notes", repo.notes]
            (started, resumed)
                `shouldBe` (["started " <> run, "run " <> run <> " " <> Text.pack repo.notes <> " " <> top], ["resumed " <> run, "run " <> run <> " " <> Text.pack repo.notes <> " " <> top])

        it "refuses another run over the worktree's unfinished one" $ \repo -> do
            run <- startedRun bin repo
            other <- state bin repo ["init", "--notes", repo.root </> "other"]
            (other.code, other.err)
                `shouldBe` ( 2
                           ,
                               [ "state init: --notes " <> Text.pack (repo.root </> "other") <> " - the worktree holds unfinished run " <> run <> " in " <> Text.pack repo.notes
                               , "fix: state init --notes " <> Text.pack repo.notes <> " resumes it, or state stop <reason> <why> ends it"
                               ]
                           )

        it "refuses a relative notes dir" $ \repo -> do
            relative <- state bin repo ["init", "--notes", "notes"]
            (relative.code, take 1 relative.err) `shouldBe` (2, ["state init: --notes notes - the notes dir is an absolute path of ASCII letters, digits and ._/@+-"])

        it "starts a run once per notes dir, and refuses one there after it stopped" $ \repo -> do
            run <- startedRun bin repo
            again <- succeeded =<< state bin repo ["init", "--notes", repo.notes]
            take 1 again `shouldBe` ["resumed " <> run]
            _ <- succeeded =<< state bin repo ["stop", "replan", "the", "plan", "is", "wrong"]
            refused <- state bin repo ["init", "--notes", repo.notes]
            (refused.code, drop 1 refused.err) `shouldBe` (2, ["fix: state init --notes <a new dir>"])

        it "fixes a refused event by the arrows this Fuel takes, never a skip it refuses" $ \repo -> do
            _ <- drive bin repo toSimplifyPr
            refused <- state bin repo ["record", "await_ci.green"]
            (refused.code, refused.err)
                `shouldBe` (2, ["state record: await_ci.green - no such arrow out of simplify_pr", "fix: state record simplify_pr.done"])

        it "overrides to a named state" $ \repo -> do
            _ <- drive bin repo []
            moved <- succeeded =<< state bin repo ["override", "review", "resume", "after", "a", "crash"]
            moved `shouldBe` ["recorded 2 overridden -> review"]
            shown <- succeeded =<< state bin repo ["show"]
            shown `shouldContain` ["step: review"]

        it "refuses an override to an unknown state, listing the states" $ \repo -> do
            _ <- drive bin repo []
            refused <- state bin repo ["override", "nowhere", "why"]
            (refused.code, refused.err)
                `shouldBe` ( 2
                           ,
                               [ "state override: override to nowhere - the flow has no single state of that name"
                               , "fix: state override <gather|plan|simplify_plan|confirm|draft|implement|refactor|review|pick|fix|re_review|describe|simplify_pr|await_ci|fix_pr|ready> <why>"
                               ]
                           )

        it "names a hand-edited bad line and appends nothing after it" $ \repo -> do
            _ <- drive bin repo []
            appendFile (eventsOf repo) "{\"v\":3,broken\n"
            before <- readFile (eventsOf repo)
            let events = Text.pack (eventsOf repo)
            for_ [("next", []), ("show", []), ("record", ["fuel", "max"])] $ \(sub, args) -> do
                bad <- state bin repo (sub : args)
                (bad.code, map (fst . Text.breakOn " - ") bad.err)
                    `shouldBe` (2, ["state " <> Text.pack sub <> ": " <> events <> " line 2 is not read", "fix: repair or move " <> events])
            after <- readFile (eventsOf repo)
            after `shouldBe` before

        describe "the review loop" $ do
            it "asks Stuck when rounds 1 and 2 pick the same row" $ \repo -> do
                _ <- drive bin repo (atReview <> reviewRound "R1" [] <> [Handback "fixer" ready] <> reviewRound "R1" [])
                advice <- succeeded =<< state bin repo ["next"]
                take 1 advice `shouldBe` ["ASK Stuck the fix loop repeats R1: go on, change course, or stop?"]

            it "refuses a pick.loop past Balanced's 3 re-reviews, then exits by pick.final" $ \repo -> do
                let rounds = concat [reviewRound label [] <> [Handback "fixer" ready] | label <- ["R1", "R2", "R3"]]
                _ <- drive bin repo (atReview <> rounds <> [Handback "review-lead" reviewed])
                advice <- succeeded =<< state bin repo ["next"]
                (take 1 advice, filter ("  Re-reviews: " `Text.isPrefixOf`) advice)
                    `shouldBe` (["RUN state record pick.final [--row <label>]... [--verdict <requirement>=<met|not-met|unverified>]..."], ["  Re-reviews: 3 of 3 used, none left"])
                refused <- state bin repo ["record", "pick.loop", "--row", "R4"]
                (refused.code, refused.err)
                    `shouldBe` (2, ["state record: the spend at pick - Re-reviews allows 3 at this Fuel, all spent", "fix: state record pick.final [--row <label>]... [--verdict <requirement>=<met|not-met|unverified>]..."])
                exited <- succeeded =<< state bin repo ["record", "pick.final"]
                recorded exited `shouldBe` ["pick.final -> describe"]

        describe "audit" $ do
            it "puts every ruling of a child run in show and in its hand-back" $ \repo -> do
                parent <- tenXAtFanOut bin repo
                w1 <- worktree repo "w1"
                child <- childRun bin w1 parent "child" "t1"
                qid <- askedQid bin w1 "Pick" ["which", "lib?"]
                let ruling = "Ruling " <> qid <> " Pick: zod - already used - none"
                _ <- succeeded =<< state bin w1 ["rule", Text.unpack qid, "--answer", "zod", "--why", "already used", "--cost", "none"]
                shown <- succeeded =<< state bin w1 ["show"]
                shown `shouldContain` ["rulings:", "  " <> ruling]
                forwarded <- succeeded =<< state bin w1 ["ask", "--kind", "Design", "which", "store?"]
                forwarded `shouldContain` [ruling]
                stopped <- succeeded =<< state bin w1 ["stop", "failed", "no", "access"]
                stopped `shouldBe` ["stopped", "HANDBACK FAILED no access", "Run: " <> child, ruling]

        describe "the 10x" $ do
            it "rules one child's question, forwards the other's Security question, and resumes both" $ \repo -> do
                parent <- tenXAtFanOut bin repo
                w1 <- worktree repo "w1"
                w2 <- worktree repo "w2"
                c1 <- childRun bin w1 parent "n1" "t1"
                c2 <- childRun bin w2 parent "n2" "t2"
                _ <- succeeded =<< state bin w1 ["ask", "--kind", "Design", "which", "store?"]
                _ <- succeeded =<< state bin w2 ["ask", "--kind", "Security", "token", "in", "env?"]
                let q1 = Text.unpack c1 <> ":1"
                    q2 = Text.unpack c2 <> ":1"
                _ <- succeeded =<< state bin repo ["rule", q1, "--answer", "postgres", "--why", "already used", "--cost", "none"]
                unfounded <- state bin repo ["rule", q2, "--answer", "yes", "--why", "fine", "--cost", "none"]
                unfounded.code `shouldBe` 2
                _ <- succeeded =<< state bin repo ["forward", q2]
                first <- succeeded =<< state bin repo ["next"]
                take 1 first `shouldBe` ["RESUME " <> c1 <> " with the answer to " <> Text.pack q1 <> ": postgres"]
                _ <- succeeded =<< state bin repo ["record", "resumed", Text.unpack c1]
                userHolds <- succeeded =<< state bin repo ["next"]
                take 1 userHolds `shouldBe` ["ASK Security " <> Text.pack q2 <> ": token in env?"]
                _ <- succeeded =<< state bin repo ["answer", q2, "use", "a", "vault"]
                second <- succeeded =<< state bin repo ["next"]
                take 1 second `shouldBe` ["RESUME " <> c2 <> " with the answer to " <> Text.pack q2 <> ": use a vault"]
                _ <- succeeded =<< state bin repo ["record", "resumed", Text.unpack c2]
                twice <- state bin repo ["record", "resumed", Text.unpack c2]
                twice.code `shouldBe` 2
                -- Each answer was written down to the child that asked it.
                shown1 <- succeeded =<< state bin w1 ["show"]
                shown2 <- succeeded =<< state bin w2 ["show"]
                shown1 `shouldSatisfy` mentions (Text.pack q1 <> " Design: which store? - postgres")
                shown2 `shouldSatisfy` mentions (Text.pack q2 <> " Security: token in env? - use a vault")
                -- The child's own answer, the same, adds nothing; another is refused.
                _ <- succeeded =<< state bin w1 ["answer", q1, "postgres", "--by", Text.unpack parent]
                other <- state bin w1 ["answer", q1, "sqlite", "--by", Text.unpack parent]
                other.code `shouldBe` 2
                relay bin repo ["HANDBACK READY " <> prUrl, "Run: " <> c1]
                third <- succeeded =<< state bin repo ["next"]
                take 1 third `shouldBe` ["AWAIT children t2"]

            it "asks the user its own breakdown Confirm, and refuses to rule on it" $ \repo -> do
                run <- startedIn bin repo ["--notes", repo.notes, "--flow", "10x"]
                for_ [["override", "confirm", "the", "plan", "is", "written"]] (succeeded <=< state bin repo)
                asked <- succeeded =<< state bin repo ["ask", "--kind", "Confirm", "start", "the", "breakdown?"]
                asked `shouldSatisfy` mentions "ASK user"
                ruled <- state bin repo ["rule", Text.unpack run <> ":1", "--answer", "yes", "--why", "fits", "--cost", "none"]
                ruled.code `shouldBe` 2

            it "rules a child's task-plan Confirm" $ \repo -> do
                parent <- tenXAtFanOut bin repo
                w1 <- worktree repo "w1"
                c1 <- childRun bin w1 parent "n1" "t1"
                _ <- succeeded =<< state bin w1 ["ask", "--kind", "Confirm", "the", "plan", "holds?"]
                _ <- succeeded =<< state bin repo ["rule", Text.unpack c1 <> ":1", "--answer", "confirmed", "--why", "fits t1", "--cost", "none"]
                resume <- succeeded =<< state bin repo ["next"]
                take 1 resume `shouldBe` ["RESUME " <> c1 <> " with the answer to " <> c1 <> ":1: confirmed"]

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

            it "spawns a task once: next waits on it from the recorded spawn, before the child starts" $ \repo -> do
                _ <- tenXAtFanOut bin repo
                spawn <- succeeded =<< state bin repo ["next"]
                take 1 spawn `shouldBe` ["SPAWN engineer --task t1 background: yes"]
                _ <- succeeded =<< state bin repo ["record", "spawning", "t1"]
                waits <- succeeded =<< state bin repo ["next"]
                take 1 waits `shouldBe` ["AWAIT children t1"]
                twice <- state bin repo ["record", "spawning", "t1"]
                twice.code `shouldBe` 2

            it "records a child's stop in its run once, a repeated next adding nothing, and triages it" $ \repo -> do
                parent <- tenXAtFanOut bin repo
                w1 <- worktree repo "w1"
                c1 <- childRun bin w1 parent "n1" "t1"
                _ <- succeeded =<< state bin w1 ["stop", "failed", "no", "access"]
                once <- logLines repo
                _ <- succeeded =<< state bin w1 ["next"]
                again <- logLines repo
                triage <- succeeded =<< state bin repo ["next"]
                again `shouldBe` once
                take 1 triage `shouldBe` ["RUN state ask --kind <kind> --from " <> c1 <> " <question> - triage: FAILED no access"]

            it "leaves a child's recorded hand-back be once its parent moved past the fan-out" $ \repo -> do
                parent <- tenXAtFanOut bin repo
                writeFile repo.prJson (pullRequest True "OPEN")
                w1 <- worktree repo "w1"
                _ <- childRun bin w1 parent "n1" "t1"
                for_ [["record", "fuel", "balanced"], ["override", "await_ci", "the", "test", "starts", "here"], ["record", "await_ci.green"], ["record", "ready.done", prUrlString]] (succeeded <=< state bin w1)
                _ <- succeeded =<< state bin w1 ["next"]
                _ <- succeeded =<< state bin repo ["record", "task", "t2", "parked", "out", "of", "scope"]
                _ <- succeeded =<< state bin repo ["next"]
                once <- logLines repo
                again <- succeeded =<< state bin w1 ["next"]
                after <- logLines repo
                (after, filter (Text.isPrefixOf "parent: ") again) `shouldBe` (once, [])

            it "tells a child its parent off the fan-out refused its hand-back, and the parent's next names it back there" $ \repo -> do
                parent <- tenXAtFanOut bin repo
                writeFile repo.prJson (pullRequest True "OPEN")
                w1 <- worktree repo "w1"
                c1 <- childRun bin w1 parent "n1" "t1"
                for_ [["record", "fuel", "balanced"], ["override", "await_ci", "the", "test", "starts", "here"], ["record", "await_ci.green"], ["record", "ready.done", prUrlString]] (succeeded <=< state bin w1)
                _ <- succeeded =<< state bin repo ["override", "breakdown", "the", "test", "leaves", "the", "fan-out"]
                refused <- succeeded =<< state bin w1 ["next"]
                _ <- succeeded =<< state bin repo ["override", "engineers", "the", "test", "returns"]
                named <- succeeded =<< state bin repo ["next"]
                refused `shouldSatisfy` mentions "parent: "
                take 1 named `shouldBe` ["RUN state handback engineer"]
                named `shouldContain` ["    state handback engineer - child " <> c1 <> " ended, its hand-back unrecorded: pipe it in"]

            it "triages a child's stop before it retries the task" $ \repo -> do
                parent <- tenXAtFanOut bin repo
                w1 <- worktree repo "w1"
                c1 <- childRun bin w1 parent "n1" "t1"
                relay bin repo ["HANDBACK BLOCKED no access to the registry", "Run: " <> c1]
                triage <- succeeded =<< state bin repo ["next"]
                take 1 triage `shouldBe` ["RUN state ask --kind <kind> --from " <> c1 <> " <question> - triage: BLOCKED no access to the registry"]
                qid <- askedQid bin repo "Stuck" ["--from", Text.unpack c1, "retry", "with", "a", "token?"]
                _ <- succeeded =<< state bin repo ["rule", Text.unpack qid, "--answer", "retry", "--why", "first try", "--cost", "one try"]
                retry <- succeeded =<< state bin repo ["next"]
                take 1 retry `shouldBe` ["SPAWN engineer --task t1 background: yes"]

            it "lists, after a crash, the child still running and the question pending" $ \repo -> do
                parent <- tenXAtFanOut bin repo
                w1 <- worktree repo "w1"
                w2 <- worktree repo "w2"
                c1 <- childRun bin w1 parent "n1" "t1"
                c2 <- childRun bin w2 parent "n2" "t2"
                _ <- succeeded =<< state bin w2 ["ask", "--kind", "Design", "which", "store?"]
                advice <- succeeded =<< state bin repo ["next"]
                take 1 advice `shouldSatisfy` mentions ("state rule " <> c2 <> ":1")
                advice `shouldContain` ["  task t1: child " <> c1 <> " running, tries 1"]

            it "awaits CI a child hands back, then leaves the fan-out once the child is ready" $ \repo -> do
                parent <- tenXAtFanOut bin repo
                writeFile repo.prJson (pullRequest True "OPEN")
                w1 <- worktree repo "w1"
                _ <- childRun bin w1 parent "n1" "t1"
                for_ [["record", "fuel", "balanced"], ["override", "await_ci", "the", "test", "starts", "here"]] (succeeded <=< state bin w1)
                _ <- succeeded =<< state bin w1 ["next"]
                _ <- succeeded =<< state bin repo ["record", "task", "t2", "parked", "out", "of", "scope"]
                awaiting <- succeeded =<< state bin repo ["next"]
                take 1 awaiting `shouldBe` ["AWAIT ci " <> prUrl]
                for_ [["await_ci.green"], ["ready.done", prUrlString]] $ \argv -> succeeded =<< state bin w1 ("record" : argv)
                _ <- succeeded =<< state bin w1 ["next"]
                left <- succeeded =<< state bin repo ["next"]
                recorded left `shouldBe` ["engineers.done -> merge"]
                drop 1 left `shouldSatisfy` mentions "AWAIT merge t1"
                early <- state bin repo ["record", "merge.done", prUrlString]
                early.code `shouldBe` 2
                _ <- succeeded =<< state bin repo ["record", "task", "t1", "merged", prUrlString]
                done <- succeeded =<< state bin repo ["next"]
                take 1 done `shouldBe` ["RUN one option below"]
                done `shouldContain` ["  options:", "    state record merge.done <url> - the flow ends", "    state record merge.next_round - back to gather, the round loop's next round"]

            it "runs from init to done, its child through the engineer flow" $ \repo -> do
                parent <- startedIn bin repo ["--notes", repo.notes, "--flow", "10x"]
                let tasks = repo.root </> "tasks.json"
                Text.writeFile tasks (breakdownJson [(plainTask "t1" []) {fuel = Low}])
                plan <- writtenPlan repo
                for_ [["fuel", "balanced"], ["gather.enough"], ["plan.done", plan], ["simplify_plan.done"], ["confirm.confirmed"], ["breakdown.done", "--tasks", tasks]] (succeeded <=< state bin repo . ("record" :))
                spawn <- succeeded =<< state bin repo ["next"]
                take 1 spawn `shouldBe` ["SPAWN engineer --task t1 background: yes"]
                w1 <- worktree repo "w1"
                _ <- childRun bin w1 parent "n1" "t1"
                -- The task's Fuel is the child's from init: it records none.
                child <- driveOn bin w1 (drop 1 trivialPath)
                child `shouldBe` drop 1 trivialTranscript
                merging <- succeeded =<< state bin repo ["next"]
                recorded merging `shouldBe` ["engineers.done -> merge"]
                for_ [["task", "t1", "merged", prUrlString], ["merge.done", prUrlString]] (succeeded <=< state bin repo . ("record" :))
                done <- succeeded =<< state bin repo ["next"]
                take 1 done `shouldBe` ["DONE " <> prUrl]

            it "keeps a round's PR open, loops back to gather with fresh budgets, and respawns the task" $ \repo -> do
                parent <- startedIn bin repo ["--notes", repo.notes, "--flow", "10x"]
                writeFile repo.prJson (pullRequest True "OPEN")
                let tasks = repo.root </> "tasks.json"
                    gathered = concat (replicate 5 [["research.spawned"], ["research.handed_back"]])
                plan <- writtenPlan repo
                let agreed = [["gather.enough"], ["plan.done", plan], ["simplify_plan.done"], ["confirm.confirmed"], ["breakdown.done", "--tasks", tasks]]
                Text.writeFile tasks (breakdownJson [roundTask "t1" prUrl])
                for_ (gathered <> agreed) (succeeded <=< state bin repo . ("record" :))
                w1 <- worktree repo "w1"
                _ <- childRun bin w1 parent "n1" "t1"
                for_ [["record", "fuel", "balanced"], ["override", "ready", "the", "test", "starts", "here"]] (succeeded <=< state bin w1)
                skipped <- succeeded =<< state bin w1 ["next"]
                recorded skipped `shouldBe` ["ready.skipped -> out"]
                merging <- succeeded =<< state bin repo ["next"]
                recorded merging `shouldBe` ["engineers.done -> merge"]
                drop 1 merging `shouldSatisfy` mentions "state record merge.next_round - back to gather, the round loop's next round"
                for_ (["merge.next_round"] : gathered) (succeeded <=< state bin repo . ("record" :))
                spent <- state bin repo ["record", "research.spawned"]
                spent.code `shouldBe` 2
                for_ agreed (succeeded <=< state bin repo . ("record" :))
                respawn <- succeeded =<< state bin repo ["next"]
                take 1 respawn `shouldBe` ["SPAWN engineer --task t1 background: yes"]

        describe "a tree of runs: a 10x under a 10x, an engineer under that" $ do
            it "climbs a question to the top and writes its one answer down to every run" $ \repo -> do
                Tree {mid, midRun, grand, grandRun} <- treeOfRuns bin repo
                let qid = grandRun <> ":1"
                    q = Text.unpack qid
                asked <- succeeded =<< state bin grand ["ask", "--kind", "Design", "which", "store?"]
                midAsked <- succeeded =<< state bin mid ["next"]
                _ <- succeeded =<< state bin mid ["forward", q]
                topAsked <- succeeded =<< state bin repo ["next"]
                _ <- succeeded =<< state bin repo ["rule", q, "--answer", "postgres", "--why", "already used", "--cost", "none"]
                topResume <- succeeded =<< state bin repo ["next"]
                midResume <- succeeded =<< state bin mid ["next"]
                shown <- traverse (succeeded <=< \run -> state bin run ["show"]) [repo, mid, grand]
                -- The grandchild's own answer, the same, is taken and changes nothing.
                _ <- succeeded =<< state bin grand ["answer", q, "postgres", "--by", Text.unpack midRun]
                again <- succeeded =<< state bin grand ["show"]
                take 1 asked `shouldBe` ["asked " <> qid]
                take 1 midAsked `shouldSatisfy` mentions ("state forward " <> qid)
                take 1 topAsked `shouldSatisfy` mentions ("state rule " <> qid)
                take 1 topResume `shouldBe` ["RESUME " <> midRun <> " with the answer to " <> qid <> ": postgres"]
                take 1 midResume `shouldBe` ["RESUME " <> grandRun <> " with the answer to " <> qid <> ": postgres"]
                map (mentions (qid <> " Design")) shown `shouldBe` [True, True, True]
                map (mentions "postgres") shown `shouldBe` [True, True, True]
                Just again `shouldBe` lastMaybe shown

            it "starts the 10x child by a --flow 10x line, spawns in the foreground below the top, and climbs a grandchild's AWAIT ci to it" $ \repo -> do
                Tree {mid, midSpawn, grand, grandFirst} <- treeOfRuns bin repo
                brief <- succeeded =<< state bin repo ["brief", "10x", "--task", "t1"]
                writeFile repo.prJson (pullRequest True "OPEN")
                _ <- succeeded =<< state bin grand ["override", "simplify_plan", "the", "test", "starts", "here"]
                grandSpawn <- succeeded =<< state bin grand ["next"]
                _ <- succeeded =<< state bin grand ["override", "await_ci", "the", "test", "starts", "here"]
                grandAwait <- succeeded =<< state bin grand ["next"]
                midAwait <- succeeded =<< state bin mid ["next"]
                topAwait <- succeeded =<< state bin repo ["next"]
                lastMaybe brief `shouldSatisfy` any (" --flow 10x " `Text.isInfixOf`)
                -- The task's Fuel is the grandchild's from init: it gathers at once, its researchers in the foreground.
                take 1 grandFirst `shouldBe` ["RUN one option below"]
                grandFirst `shouldSatisfy` mentions "spawn a researcher in the foreground"
                map (take 1) [midSpawn, grandSpawn] `shouldBe` [["SPAWN engineer --task g1 background: no"], ["SPAWN researcher background: no"]]
                map (take 1) [grandAwait, midAwait] `shouldBe` replicate 2 ["HANDBACK AWAIT ci " <> prUrl]
                take 1 topAwait `shouldBe` ["AWAIT ci " <> prUrl]

        describe "brief" $ do
            it "gives a refactorer its step's task and the stop rule" $ \repo -> do
                _ <- drive bin repo []
                stopRule <- succeeded =<< state bin repo ["render", "stop-rule"]
                brief <- succeeded =<< state bin repo ["brief", "refactorer"]
                take 1 brief `shouldBe` ["## refactor"]
                brief `shouldSatisfy` (stopRule `isSuffixOf`)

            it "gives a fixer only the step the run is at, and a worker no command of the lead's" $ \repo -> do
                _ <- drive bin repo (atReview <> [Commit, Handback "review-lead" reviewed, Record ["pick.loop", "--row", "R1"]])
                fixer <- succeeded =<< state bin repo ["brief", "fixer"]
                filter ("## " `Text.isPrefixOf`) fixer `shouldBe` ["## fix"]
                for_ ["researcher", "implementer", "refactorer", "fixer"] $ \role -> do
                    brief <- succeeded =<< state bin repo ["brief", role]
                    brief `shouldSatisfy` (not . any (\line -> any (`Text.isInfixOf` line) ["state record", "state brief"]))

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
                drop 1 (dropWhile (/= "") brief) `shouldBe` ["state init --notes <dir> --parent " <> run <> " --parent-log " <> Text.pack (eventsOf repo) <> " --task t1"]

        describe "the hooks" $ do
            it "are silent in a worktree with no run" $ \repo -> do
                said <- hook hookBin repo "resume" (sessionStart repo)
                (said.code, said.out) `shouldBe` (0, [])

            it "tell a resumed session where its run stands" $ \repo -> do
                _ <- drive bin repo []
                said <- succeeded =<< hook hookBin repo "resume" (sessionStart repo)
                said `shouldSatisfy` mentions "step: gather"

            it "record a hand-back seen twice once, appending what they recorded" $ \repo -> do
                _ <- drive bin repo (init toImplement)
                _ <- succeeded =<< hook hookBin repo "bind" (spawnResult repo Null "implementer" "a1")
                before <- logLines repo
                first <- succeeded =<< hook hookBin repo "handback" (handedBack repo "implementer")
                once <- logLines repo
                again <- succeeded =<< hook hookBin repo "handback" (handedBack repo "implementer")
                twice <- logLines repo
                first `shouldSatisfy` mentions "state: recorded"
                once `shouldSatisfy` (> before)
                (again, twice) `shouldBe` ([], once)

            it "are silent off the branch the draft PR bound the run to" $ \repo -> do
                _ <- drive bin repo (init toImplement)
                git repo ["checkout", "-q", "-b", "other"]
                said <- succeeded =<< hook hookBin repo "resume" (sessionStart repo)
                said `shouldBe` []

            it "are silent once the drafted PR is merged or closed" $ \repo -> do
                _ <- drive bin repo (init toImplement)
                _ <- succeeded =<< hook hookBin repo "bind" (spawnResult repo Null "implementer" "a1")
                before <- logLines repo
                for_ ["MERGED", "CLOSED"] $ \over -> do
                    writeFile repo.prJson (pullRequest False over)
                    resumed <- succeeded =<< hook hookBin repo "resume" (sessionStart repo)
                    handed <- succeeded =<< hook hookBin repo "handback" (handedBack repo "implementer")
                    (resumed, handed) `shouldBe` ([], [])
                after <- logLines repo
                after `shouldBe` before

            it "are silent on a log they do not read" $ \repo -> do
                _ <- startedRun bin repo
                writeFile (eventsOf repo) "{\"seq\":0,\"ts\":\"t\",\"head\":null,\"session\":null,\"event\":{\"type\":\"started\",\"notes\":\"n\",\"version\":2}}\n"
                said <- succeeded =<< hook hookBin repo "resume" (sessionStart repo)
                said `shouldBe` []

            it "tell a log line they do not read, as context" $ \repo -> do
                _ <- drive bin repo []
                appendFile (eventsOf repo) "{\"v\":3,broken\n"
                said <- succeeded =<< hook hookBin repo "resume" (sessionStart repo)
                said `shouldSatisfy` mentions "line 2 is not read"

            it "records a restart of the lead's resumed session, so its lost child is sent again" $ \repo -> do
                c1 <- childAtWork bin repo
                resumed <- succeeded =<< hook hookBin repo "resume" (sessionFrom "resume" repo)
                resumed `shouldSatisfy` mentions "restarted"
                lost <- succeeded =<< state bin repo ["next"]
                take 1 lost `shouldBe` ["RESUME " <> c1 <> " lost at a restart: a fresh engineer with its spawn prompt"]

            it "records no restart at a compaction, which keeps the lead's child" $ \repo -> do
                _ <- childAtWork bin repo
                compacted <- succeeded =<< hook hookBin repo "resume" (sessionFrom "compact" repo)
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
                it "record the main session's worker spawn and hand-back in the run its init bound it to" $ \repo -> do
                    run <- initBound bin hookBin repo Null repo ["--notes", repo.notes]
                    _ <- succeeded =<< state bin repo ["record", "fuel", "balanced"]

                    said <- workerAt hookBin repo Null "w1"

                    said `shouldSatisfy` mentions ("run " <> run <> ": state: recorded")
                    loggedTypes repo.notes `shouldReturnContaining` ["research.spawned", "research.handed_back"]

                it "record a 10x session's, whose run is outside the repo its hooks fire in" $ \repo -> do
                    let tenX = repo.root </> "tenx"
                    createDirectory tenX
                    git repo {work = tenX} ["init", "-q"]
                    run <- initBound bin hookBin repo Null repo {work = tenX} ["--notes", tenX, "--flow", "10x"]

                    said <- workerAt hookBin repo Null "w1"

                    said `shouldSatisfy` mentions ("run " <> run <> ": state: recorded")
                    loggedTypes tenX `shouldReturnContaining` ["research.spawned", "research.handed_back"]

                it "record a child engineer's worker spawn in its own run, not its parent's, at depth 1" $ \repo -> do
                    (engineer, _) <- childEngineer bin hookBin repo
                    before <- logLines repo

                    said <- succeeded =<< hook hookBin repo "spawn" (spawned' repo engineer "researcher")

                    after <- logLines repo
                    said `shouldSatisfy` mentions "research.spawned"
                    loggedTypes (repo.root </> "n1") `shouldReturnContaining` ["research.spawned"]
                    after `shouldBe` before

                it "record a depth-2 worker's hand-back made before its spawner's hook bound it, as a foreground one is" $ \repo -> do
                    (engineer, _) <- childEngineer bin hookBin repo
                    _ <- succeeded =<< hook hookBin repo "spawn" (spawned' repo engineer "researcher")

                    early <- succeeded =<< hook hookBin repo "handback" (reportedBy repo (worker "w2" "researcher") researched)
                    bound <- succeeded =<< hook hookBin repo "bind" (spawnResult repo engineer "researcher" "w2")

                    early `shouldBe` []
                    bound `shouldSatisfy` mentions "state: recorded"
                    loggedTypes (repo.root </> "n1") `shouldReturnContaining` ["research.spawned", "research.handed_back"]

                it "record a depth-2 worker's hand-back made after its spawner's hook bound it, as a background one is" $ \repo -> do
                    (engineer, _) <- childEngineer bin hookBin repo
                    _ <- succeeded =<< hook hookBin repo "spawn" (spawned' repo engineer "researcher")

                    _ <- succeeded =<< hook hookBin repo "bind" (spawnResult repo engineer "researcher" "w2")
                    back <- succeeded =<< hook hookBin repo "handback" (reportedBy repo (worker "w2" "researcher") researched)

                    back `shouldSatisfy` mentions "state: recorded"
                    loggedTypes (repo.root </> "n1") `shouldReturnContaining` ["research.spawned", "research.handed_back"]

                it "record a child engineer's own hand-back in its parent's log by its state call, its hand-back hook adding nothing" $ \repo -> do
                    (engineer, w1) <- childEngineer bin hookBin repo

                    _ <- succeeded =<< state bin w1 ["stop", "failed", "no", "access"]
                    once <- logLines repo
                    hooked <- succeeded =<< hook hookBin repo "handback" (reportedBy repo engineer "FAILED no access\n")
                    after <- logLines repo

                    loggedTypes repo.notes `shouldReturnContaining` ["handed_back"]
                    (hooked, after) `shouldBe` ([], once)

            describe "route each agent's state calls to its run" $ do
                it "deny a child engineer's state call from its parent's checkout, naming the cd to its own worktree" $ \repo -> do
                    (engineer, w1) <- childEngineer bin hookBin repo
                    top <- Text.strip . Text.pack <$> gitOut w1 ["rev-parse", "--show-toplevel"]

                    said <- succeeded =<< hook hookBin repo "route" (ranIn repo engineer "state next")

                    replyField "decision" said `shouldBe` Just "deny"
                    replyField "reason" said `shouldSatisfy` maybe False (("fix: cd " <> top <> " && state next\n") `Text.isSuffixOf`)

                it "let a child engineer's state call run once it cds to its own worktree" $ \repo -> do
                    (engineer, w1) <- childEngineer bin hookBin repo

                    said <- succeeded =<< hook hookBin repo "route" (ranIn repo engineer ("cd " <> Text.pack w1.work <> " && state next"))

                    said `shouldBe` []

                it "let an agent bound to no run call state anywhere" $ \repo -> do
                    _ <- drive bin repo []

                    said <- succeeded =<< hook hookBin repo "route" (ranIn repo (worker "e9" "engineer") "state next")

                    said `shouldBe` []

            describe "tell how work begins" $ do
                it "tell a spawned engineer its run starts at its prompt's init line" $ \repo -> do
                    said <- succeeded =<< hook hookBin repo "begin" (agentStarted repo (worker "e1" "engineer"))

                    replyField "context" said `shouldSatisfy` maybe False ("the `state init` line" `Text.isInfixOf`)

                it "give a spawned implementer what state brief implementer gives" $ \repo -> do
                    _ <- drive bin repo []
                    brief <- succeeded =<< state bin repo ["brief", "implementer"]

                    said <- succeeded =<< hook hookBin repo "begin" (agentStarted repo (worker "i1" "implementer"))

                    replyField "context" said `shouldBe` Just (Text.unlines brief)

                it "tell a typed /engineer it begins with state" $ \repo -> do
                    said <- succeeded =<< hook hookBin repo "begin" (hookEvent repo Null ["event" .= String "promptExpansion", "skill" .= String "engineer"])

                    replyField "context" said `shouldSatisfy` maybe False ("`state init ...`" `Text.isInfixOf`)

            it "tell the lead how to record the answer to a question put to the user" $ \repo -> do
                _ <- drive bin repo []
                qid <- askedQid bin repo "Design" ["which", "store?"]
                said <- succeeded =<< hook hookBin repo "asked" (askedUser repo)
                said `shouldSatisfy` mentions ("state answer " <> qid <> " <answer>")

-- | One call of the binary: its exit code and its output, line by line.
data Ran = Ran {code :: Int, out :: [Text], err :: [Text]}

state :: FilePath -> Repo -> [String] -> IO Ran
state bin repo = stateIn bin repo ""

stateIn :: FilePath -> Repo -> String -> [String] -> IO Ran
stateIn bin repo stdin argv = do
    (exit, out, err) <- readCreateProcessWithExitCode (proc bin argv) {cwd = Just repo.work, env = Just repo.env} stdin
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
sessionFrom source repo = hookEvent repo Null ["event" .= String "sessionStart", "source" .= String source]

-- | A subagent of this role hands back @READY@.
handedBack :: Repo -> Text -> String
handedBack repo role = reportedBack repo role (ready "")

-- | A subagent of this role hands back this message.
reportedBack :: Repo -> Text -> Text -> String
reportedBack repo role = reportedBy repo (worker "a1" role)

-- | This subagent hands back this message, its hook firing in the repo's worktree.
reportedBy :: Repo -> Value -> Text -> String
reportedBy repo agent message =
    hookEvent repo agent ["event" .= String "beforeTool", "tool" .= String "handback", "input" .= object ["message" .= String message], "history" .= ([] :: [Text])]

-- | A subagent, by its id and role, as the hook payload names it.
worker :: Text -> Text -> Value
worker agentId role = object ["id" .= agentId, "role" .= role]

-- | The lead spawns a subagent of this role.
spawned :: Repo -> Text -> String
spawned repo = spawned' repo Null

-- | This agent (the lead: @Null@) spawns a subagent of this role.
spawned' :: Repo -> Value -> Text -> String
spawned' repo agent role = hookEvent repo agent ["event" .= String "beforeTool", "tool" .= String "delegate", "input" .= object ["subagent_type" .= role], "history" .= ([] :: [Text])]

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
        , "input" .= object ["description" .= String "a worker", "prompt" .= String "state brief", "subagent_type" .= role, "run_in_background" .= False]
        , "output" .= object ["status" .= String "completed", "agentId" .= child, "agentType" .= role]
        , "context" .= Null
        ]

{- | @cd <dir> && state init <args>@, run in @dir@ by this agent, whose hooks
fire in @at@'s worktree; then its PostToolUse on Bash binds it. The run's id.
-}
initBound :: FilePath -> FilePath -> Repo -> Value -> Repo -> [String] -> IO Text
initBound bin hookBin at agent dir argv = do
    printed <- succeeded =<< state bin dir ("init" : argv)
    let command = "cd " <> dir.work <> " && state init " <> unwords argv
    _ <- succeeded =<< hook hookBin at "bind" (ranShell at agent command printed)
    case printed of
        [line, _] | Just run <- Text.stripPrefix "started " line -> pure run
        other -> fail ("not started: " <> show other)

-- | This agent's shell command done, printing these lines: a PostToolUse on Bash.
ranShell :: Repo -> Value -> String -> [Text] -> String
ranShell repo agent command printed =
    hookEvent
        repo
        agent
        [ "event" .= String "afterTool"
        , "tool" .= String "shell"
        , "input" .= object ["command" .= command, "description" .= String "start the run"]
        , "output" .= object ["stdout" .= Text.unlines printed, "stderr" .= String "", "interrupted" .= False]
        , "context" .= Null
        ]

{- | This agent spawns a researcher @w@, bound by the spawn's PostToolUse, which
hands back its report; every hook fires in the repo's worktree. What the
hand-back's hook replied.
-}
workerAt :: FilePath -> Repo -> Value -> Text -> IO [Text]
workerAt hookBin repo agent w = do
    _ <- succeeded =<< hook hookBin repo "spawn" (spawned' repo agent "researcher")
    _ <- succeeded =<< hook hookBin repo "bind" (spawnResult repo agent "researcher" w)
    succeeded =<< hook hookBin repo "handback" (reportedBy repo (worker w "researcher") researched)

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
    _ <- initBound bin hookBin repo engineer w1 ["--notes", repo.root </> "n1", "--parent", Text.unpack parent, "--parent-log", eventsOf repo, "--task", "t1"]
    _ <- succeeded =<< state bin w1 ["record", "fuel", "balanced"]
    pure (engineer, w1)

-- | The event types a run's log holds, its notes dir given.
loggedTypes :: FilePath -> IO [Text]
loggedTypes dir = map (eventType . (.event)) . rights . map decodeLine . Text.lines <$> Text.readFile (dir </> "events.jsonl")

-- | Each expected entry is in the list.
shouldReturnContaining :: IO [Text] -> [Text] -> IO ()
shouldReturnContaining act expected = act >>= \got -> for_ expected (\e -> got `shouldContain` [e])

-- | This agent's shell command about to run, its hook firing in the repo's worktree.
ranIn :: Repo -> Value -> Text -> String
ranIn repo agent command = hookEvent repo agent ["event" .= String "beforeTool", "tool" .= String "shell", "input" .= object ["command" .= command], "history" .= ([] :: [Text])]

-- | This subagent starting, its hook firing in the repo's worktree.
agentStarted :: Repo -> Value -> String
agentStarted repo agent = hookEvent repo agent ["event" .= String "agentStart"]

-- | A text field of the reply a hook printed.
replyField :: Aeson.Key -> [Text] -> Maybe Text
replyField key said = case Aeson.decodeStrictText (Text.concat said) of
    Just (Object fields) | Just (String value) <- KeyMap.lookup key fields -> Just value
    _ -> Nothing

askedUser :: Repo -> String
askedUser repo = hookEvent repo Null ["event" .= String "afterTool", "tool" .= String "ask", "input" .= object [], "output" .= String "ok", "context" .= Null]

-- | The neutral hook event of the lead's (a @Null@ agent) or a subagent's session in the worktree.
hookEvent :: Repo -> Value -> [Pair] -> String
hookEvent repo agent fields = LBS8.unpack (encode (object (["session" .= String "s1", "cwd" .= repo.work, "agent" .= agent] <> fields)))

mentions :: Text -> [Text] -> Bool
mentions needle = any (needle `Text.isInfixOf`)

logLines :: Repo -> IO Int
logLines repo = length . Text.lines <$> Text.readFile (eventsOf repo)

-- | The output of a call that must succeed.
succeeded :: Ran -> IO [Text]
succeeded ran
    | ran.code == 0 = pure ran.out
    | otherwise = [] <$ expectationFailure ("exit " <> show ran.code <> ": " <> Text.unpack (Text.unlines ran.err))

-- | @init@ in the worktree's notes; the run's id.
startedRun :: FilePath -> Repo -> IO Text
startedRun bin repo = startedIn bin repo ["--notes", repo.notes]

-- | @init@ with these arguments; the run's id.
startedIn :: FilePath -> Repo -> [String] -> IO Text
startedIn bin repo argv =
    (succeeded =<< state bin repo ("init" : argv)) >>= \case
        [line, _] | Just run <- Text.stripPrefix "started " line -> pure run
        other -> fail ("not started: " <> show other)

{- | A 10x run at its fan-out with tasks @t1@ and @t2@, @t2@ depending on
@t1@; the run's id.
-}
tenXAtFanOut :: FilePath -> Repo -> IO Text
tenXAtFanOut bin repo = do
    run <- startedIn bin repo ["--notes", repo.notes, "--flow", "10x"]
    let tasks = repo.root </> "tasks.json"
    Text.writeFile tasks (breakdownJson [plainTask "t1" [], plainTask "t2" ["t1"]])
    for_ [["override", "breakdown", "the", "plan", "is", "agreed"], ["record", "breakdown.done", "--tasks", tasks]] (succeeded <=< state bin repo)
    pure run

-- | The child run a parent's brief starts for this task, its notes in @dir@ under the repo's root; its id.
childRun :: FilePath -> Repo -> Text -> FilePath -> Text -> IO Text
childRun bin repo parent dir task = startedIn bin repo ["--notes", repo.root </> dir, "--parent", Text.unpack parent, "--parent-log", eventsOf repo, "--task", Text.unpack task]

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
data Tree = Tree {top :: Text, mid :: Repo, midRun :: Text, midSpawn :: [Text], grand :: Repo, grandRun :: Text, grandFirst :: [Text]}

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
    for_ [["override", "breakdown", "the", "plan", "is", "agreed"], ["record", "breakdown.done", "--tasks", file]] (succeeded <=< state bin repo)
    succeeded =<< state bin repo ["next"]

-- | The child run the parent's brief for this role and task starts in the child's notes, by the brief's init line; its id.
briefedRun :: FilePath -> Repo -> String -> String -> Repo -> IO Text
briefedRun bin parent role task child = do
    brief <- succeeded =<< state bin parent ["brief", role, "--task", task]
    case map Text.unpack . Text.words <$> lastMaybe brief of
        Just ("state" : "init" : flags) -> startedIn bin child [if flag == "<dir>" then child.notes else flag | flag <- flags]
        other -> fail ("no init line: " <> show other)

lastMaybe :: [a] -> Maybe a
lastMaybe = foldl (\_ line -> Just line) Nothing

-- | @state ask --kind <kind> <question>@; the id it prints.
askedQid :: FilePath -> Repo -> String -> [String] -> IO Text
askedQid bin repo kind question = do
    [asked, _] <- succeeded =<< state bin repo (["ask", "--kind", kind] <> question)
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
    handback : run : _ | Just report <- Text.stripPrefix "HANDBACK " handback -> void (succeeded =<< stateIn bin parent (Text.unpack (Text.unlines [report, run])) ["handback", "engineer"])
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
        Override to -> succeeded =<< state bin repo ["override", to, "the", "test", "starts", "here"]
        -- The spawn's PreToolUse, then its PostToolUse, which binds the worker.
        Spawn role -> (<>) <$> hooked "spawn" (spawned repo role) <*> hooked "bind" (spawnResult repo Null role "a1")
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
    contextLines reply = maybe [] (map (unstated . aboutNoRun) . Text.lines) (replyField "context" [reply])

unstated :: Text -> Text
unstated line = fromMaybe line (Text.stripPrefix "state: " line)

-- | A hook's line without the run it names, @run <id>: @.
aboutNoRun :: Text -> Text
aboutNoRun line = case Text.stripPrefix "run " line of
    Just rest | (_, after) <- Text.breakOn ": " rest, not (Text.null after) -> Text.drop 2 after
    _ -> line

-- | The @recorded <seq> <event> -> <state>@ lines of an output, without their sequence numbers.
recorded :: [Text] -> [Text]
recorded = concatMap $ \line -> case Text.words line of
    ["recorded", _, event, "->", at] -> [event <> " -> " <> at]
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
    [ Spawn "researcher"
    , AskUser "Scope" ["which", "scope?"]
    , HandsBack "researcher" researched
    , Record ["gather.enough"]
    , Planned
    , Handback "researcher" ready
    , Record ["confirm.confirmed"]
    , OpenPr
    , Commit
    , Handback "implementer" ready
    ]

-- | A Balanced run to its first Simplify of the PR.
toSimplifyPr :: [Act]
toSimplifyPr =
    Record ["fuel", "balanced"]
        : toImplement
            <> [Handback "review-lead" reviewed, Record ["pick.final"], Handback "fixer" ready]

balancedPath :: [Act]
balancedPath = toSimplifyPr <> [Handback "fixer" simplified, Record ["await_ci.green"], Record ["ready.done", prUrlString]]

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

-- | Balanced, its review clean: no pick and no fix loop.
cleanPath :: [Act]
cleanPath =
    Record ["fuel", "balanced"]
        : toImplement
            <> [Record ["review.clean"], Handback "fixer" ready, Handback "fixer" simplified, Record ["await_ci.green"], Record ["ready.done", prUrlString]]

cleanTranscript :: [Text]
cleanTranscript =
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
    , "review.clean -> describe"
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
    , Record ["ready.done", prUrlString]
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

-- | Balanced, moved to the review by override.
atReview :: [Act]
atReview = [Record ["fuel", "balanced"], Override "review"]

-- | A review back with its rows, and the lead's picks: a loop on this row.
reviewRound :: String -> [String] -> [Act]
reviewRound label verdicts = [Commit, Handback "review-lead" reviewed, Record (["pick.loop", "--row", label] <> verdicts)]

prUrl :: Text
prUrl = Text.pack prUrlString

prUrlString :: String
prUrlString = "https://github.com/o/r/pull/1"

-- | The branch's PR as @gh pr view --json@ prints it: draft or not, and its GitHub state.
pullRequest :: Bool -> String -> String
pullRequest isDraft prState =
    "{\"url\":\"" <> prUrlString <> "\",\"baseRefName\":\"main\",\"headRefName\":\"feat\",\"isDraft\":" <> (if isDraft then "true" else "false") <> ",\"state\":\"" <> prState <> "\"}"

-- | A temp worktree, its notes, the file the scripted @gh@ reads, and the environment of every call.
data Repo = Repo {root :: FilePath, work :: FilePath, notes :: FilePath, prJson :: FilePath, env :: [(String, String)]}

eventsOf :: Repo -> FilePath
eventsOf repo = repo.notes </> "events.jsonl"

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
    -- `gh pr view --json ...` as gh answers it: the PR, or no PR for the branch.
    writeExecutable (bin </> "gh") . unlines $
        [ "#!" <> sh
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
    readCreateProcessWithExitCode (proc "git" argv) {cwd = Just repo.work, env = Just repo.env} "" >>= \case
        (ExitSuccess, out, _) -> pure out
        (ExitFailure _, _, err) -> fail ("git " <> unwords argv <> ": " <> err)
