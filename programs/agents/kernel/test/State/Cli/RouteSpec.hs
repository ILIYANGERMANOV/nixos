module State.Cli.RouteSpec (spec) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Hedgehog (Gen, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import State.Cli.Route
import State.Protocol.Binding (Binding (..))
import State.Run.Id (RunId, parseRunId)
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
            [calls "cd /wt && state next", calls "cd wt && state show; state pending"]
                `shouldBe` [[at "/wt" "next" "state next"], [at "/work/wt" "show" "state show", at "/work/wt" "pending" "state pending"]]

        it "splits at every list and pipe operator" $
            map (map (.sub) . calls) ["state next || state show", "state next | tail -5", "state next & state show", "state next\nstate show"]
                `shouldBe` [["next", "show"], ["next"], ["next", "show"], ["next", "show"]]

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
            sub <- forAll (Gen.element ["next", "show", "pending"])
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
            route bound [(at "/tmp" "show" "state show", Nothing)] `shouldSatisfy` maybe False ("state show: /tmp is in no git worktree" `Text.isPrefixOf`)

        it "denies by the first call at another run" $
            route bound [(next, Just "/repo/.claude/worktrees/child"), (at "/repo" "show" "state show", Just "/repo")] `shouldSatisfy` maybe False ("state show:" `Text.isPrefixOf`)

        it "quotes a bound worktree a shell would split" $
            route bound {toplevel = "/home/me/my repo"} [(next, Just "/repo")] `shouldSatisfy` maybe False ("fix: cd '/home/me/my repo' && state next\n" `Text.isSuffixOf`)

-- | An absolute directory of plain path words, which a shell reads as written.
genDir :: Gen FilePath
genDir = concatMap ('/' :) <$> Gen.list (Range.linear 1 4) (Gen.string (Range.linear 1 8) (Gen.element (['a' .. 'z'] <> ['0' .. '9'] <> "._-")))

runId :: Text -> RunId
runId = fromMaybe (error "no run id") . parseRunId
