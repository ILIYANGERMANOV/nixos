module State.Cli.RouteSpec (spec) where

import Data.Text qualified as Text
import Hedgehog (Gen, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import State.Cli.Route
import State.Protocol.Binding (Binding (..))
import State.Protocol.Hook (Gate (..), LeadSkill (..))
import State.Role (FlowName (..))
import State.Run.Event (AgentRole (..))
import State.Run.EventGen (runId)
import State.Run.RunGen (loadSteps)
import Test.Hspec (Spec, describe, it, runIO, shouldBe, shouldSatisfy)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "routing a shell command's state calls" $ do
    steps <- runIO loadSteps
    let calls = stateCalls steps "/work"
        at = StateCall

    describe "the state calls of a command" $ do
        it "finds a call in the hook's directory" $
            calls "state next" `shouldBe` [at "/work" "next" "state next"]

        it "moves the calls after a cd, absolute or relative to the directory before" $
            [calls "cd /wt && state next", calls "cd wt && state pending; state next"]
                `shouldBe` [[at "/wt" "next" "state next"], [at "/work/wt" "pending" "state pending", at "/work/wt" "next" "state next"]]

        it "splits at every list and pipe operator" $
            map (map (.sub) . calls) ["state next || state pending", "state next | tail -5", "state next & state pending", "state next\nstate pending"]
                `shouldBe` [["next", "pending"], ["next"], ["next", "pending"], ["next", "pending"]]

        it "reads quotes, so an operator in an argument splits nothing" $
            calls "state ask --kind Design 'a && b; c' \"d | e\""
                `shouldBe` [at "/work" "ask" "state ask --kind Design 'a && b; c' \"d | e\""]

        it "reads a line continuation as nothing" $
            calls "cd /wt \\\n  && state next" `shouldBe` [at "/wt" "next" "state next"]

        it "drops a redirection from the call's argv but keeps it in its text" $
            calls "state next 2>&1 | tail -3" `shouldBe` [at "/work" "next" "state next 2>&1"]

        it "routes no call that reads no run: init, help, render, or argv state refuses" $
            map calls ["state init --notes /n", "state help", "state next --help", "state render stop-rule", "state nope"]
                `shouldBe` replicate 5 []

        it "routes no show, which names its run, but routes next, pending and a write" $
            map (map (.sub) . calls) ["state show", "state next", "state pending", "state void 3 --why typo"]
                `shouldBe` [[], ["next"], ["pending"], ["void"]]

        it "routes nothing it cannot read: a subshell, a substitution, a heredoc, an open quote" $
            map calls ["(cd /wt && state next)", "state record x --note \"$(date)\"", "state ask <<EOF\nhi\nEOF", "state next 'open"]
                `shouldBe` replicate 4 []

        it "routes no call after a cd to a directory it cannot name" $
            map calls ["cd $WT && state next", "cd ~/wt && state next", "cd - && state next", "cd && state next"]
                `shouldBe` replicate 4 []

        it "ignores a comment and a command that is not state" $
            calls "git status # state next" `shouldBe` []

        it "a_call_after_cd_runs_in_that_directory" . hedgehog $ do
            dir <- forAll genDir
            sub <- forAll (Gen.element ["next", "pending"])
            stateCalls steps "/work" ("cd " <> Text.pack dir <> " && state " <> sub) === [at dir sub ("state " <> sub)]

        it "a_single_quoted_directory_reads_back_whole" . hedgehog $ do
            dir <- forAll (Gen.string (Range.linear 1 20) (Gen.filter (/= '\'') Gen.unicode))
            map (.dir) (stateCalls steps "/" ("cd '/" <> Text.pack dir <> "' && state next")) === ["/" <> dir]

    describe "the verdict" $ do
        let bound = Binding (runId "0a1b2c3d") "/notes" "/repo/.claude/worktrees/child"
            next = at "/repo" "next" "state next"
        it "allows a call in the bound worktree" $
            route bound [(next, Just "/repo/.claude/worktrees/child")] `shouldBe` Nothing

        it "denies a call in another worktree, even the one the bound worktree sits in, naming the fix" $
            route bound [(next, Just "/repo")]
                `shouldBe` Just
                    ( "state next: the run at /repo is not this agent's - this agent is bound to run 0a1b2c3d at /repo/.claude/worktrees/child\n"
                        <> "fix: cd /repo/.claude/worktrees/child && state next\n"
                    )

        it "denies a call in no worktree" $
            route bound [(at "/tmp" "pending" "state pending", Nothing)] `shouldSatisfy` maybe False ("state pending: /tmp is in no git worktree" `Text.isPrefixOf`)

        it "denies by the first call at another run" $
            route bound [(next, Just "/repo/.claude/worktrees/child"), (at "/repo" "pending" "state pending", Just "/repo")] `shouldSatisfy` maybe False ("state pending:" `Text.isPrefixOf`)

        it "quotes a bound worktree a shell would split" $
            route bound {toplevel = "/home/me/my repo"} [(next, Just "/repo")] `shouldSatisfy` maybe False ("fix: cd '/home/me/my repo' && state next\n" `Text.isSuffixOf`)

    gateSpec
    readOnlySpec

gateSpec :: Spec
gateSpec = describe "the gate of an agent bound to no run" $ do
    let denied lead = map (gate lead)
        writes = [Edits, Writes, Spawns] <> map RunsShell recordedCommands
        initFix = "fix: state init --notes /tmp/engineer-<owner>-<repo>-<slug>/\n"
    it "denies a typed /engineer's edit, naming the init that starts its run" $
        gate engineer Edits
            `shouldBe` Just
                ( "state init: this lead has no run, so its edit waits - a lead's writes go in its run's record, which `state init` starts\n"
                    <> initFix
                )

    it "denies a skill lead's every write, spawn, commit, push and PR opened or merged" $
        denied engineer writes `shouldSatisfy` all (maybe False (initFix `Text.isSuffixOf`))

    it "points a typed /10x-engineer at the init its run directory takes" $
        denied (SkillLead TenXSkill) writes `shouldSatisfy` all (maybe False ("fix: state init --notes \"$PWD\" --flow 10x, in the run directory Intake or Resume names\n" `Text.isSuffixOf`))

    it "points a typed /architect at the architect's init" $
        denied (SkillLead ArchitectSkill) writes `shouldSatisfy` all (maybe False ("fix: state init --notes /tmp/architect-<owner>-<repo>-<slug>/ --flow architect\n" `Text.isSuffixOf`))

    it "points a spawned lead at the init line in its prompt" $
        denied RoleLead writes `shouldSatisfy` all (maybe False ("fix: run the `state init` line in your prompt, as written\n" `Text.isSuffixOf`))

    it "names the command it denies, found among a compound's simple commands" $
        gate engineer (RunsShell "git add . && git commit -m x") `shouldSatisfy` maybe False ("state init: this lead has no run, so `git commit -m x` waits" `Text.isPrefixOf`)

    it "lets a lead read, research and run state" $
        denied engineer (map RunsShell readCommands) `shouldBe` map (const Nothing) readCommands

    it "lets a command it cannot read go on" $
        denied RoleLead (map RunsShell ["(git commit -m x)", "echo \"$(git push)\"", "git commit -m 'open"]) `shouldBe` replicate 3 Nothing

    it "never_gates_an_agent_that_leads_nothing" . hedgehog $ do
        call <- forAll (Gen.element (writes <> map RunsShell readCommands))
        gate NotLead call === Nothing

    it "leads by a role that leads a flow, else by a lead skill begun" $
        [leadOf (Just (AgentRole "engineer")) (Just TenXSkill), leadOf (Just (AgentRole "10x")) Nothing, leadOf (Just (AgentRole "implementer")) Nothing, leadOf Nothing Nothing, leadOf Nothing (Just TenXSkill)]
            `shouldBe` [RoleLead, RoleLead, NotLead, NotLead, SkillLead TenXSkill]
  where
    engineer = SkillLead EngineerSkill
    recordedCommands = ["git commit -m x", "git push", "git -C /wt push -u origin HEAD", "gh pr create --draft", "gh pr merge 7 --squash", "git add . && git commit -m x"]
    readCommands = ["git status", "git log --oneline -3", "gh pr view 7", "state next", "state init --notes /tmp/n --task t", "echo git commit"]

readOnlySpec :: Spec
readOnlySpec = describe "the architect's read-only run" $ do
    let codeWrites = [Edits, Writes] <> map RunsShell ["git commit -m x", "git -C /wt push -u origin HEAD", "gh pr create --draft", "gh pr merge 7 --squash"]
        ticketCalls = [Spawns] <> map RunsShell ["gh issue create --repo o/r --title t --body b", "gh issue edit 1 --repo o/r --body-file - <<'EOF'\nbody\nEOF", "git status", "state next"]
    it "denies an edit, a write, a commit, a push and a PR opened or merged, naming the ticket as the fix" $
        map (readOnly ArchitectFlow) codeWrites `shouldSatisfy` all (maybe False ("fix: write the design into the ticket" `Text.isInfixOf`))

    it "lets a researcher spawn, the ticket be written and reads go on" $
        map (readOnly ArchitectFlow) ticketCalls `shouldBe` map (const Nothing) ticketCalls

    it "never_denies_the_engineer_or_the_10x" . hedgehog $ do
        flow <- forAll (Gen.element [EngineerFlow, TenXFlow])
        call <- forAll (Gen.element (codeWrites <> ticketCalls))
        readOnly flow call === Nothing

-- | An absolute directory of plain path words, which a shell reads as written.
genDir :: Gen FilePath
genDir = concatMap ('/' :) <$> Gen.list (Range.linear 1 4) (Gen.string (Range.linear 1 8) (Gen.element (['a' .. 'z'] <> ['0' .. '9'] <> "._-")))
