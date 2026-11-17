module State.Protocol.BindingSpec (spec) where

import Data.Char (isSpace)
import Data.Text qualified as Text
import Hedgehog (Gen, forAll, tripping, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import State.Protocol.Binding
import State.Run.Event (SessionId (..))
import State.Run.EventGen (genRunId, runId)
import State.Run.Id (runIdText)
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = describe "the agent-to-run binding" $ do
    describe "its codec, init's run line" $ do
        it "binding_round_trips" . hedgehog $ do
            binding <- forAll genBinding
            tripping binding renderBinding parseBinding

        it "binding_read_from_init_output" . hedgehog $ do
            binding <- forAll genBinding
            verb <- forAll (Gen.element ["started", "resumed"])
            bindingIn (Text.unlines [verb <> " " <> runIdText binding.run, renderBinding binding]) === Just binding

        it "keeps the spaces of a toplevel, which comes last" $
            parseBinding "run 0a1b2c3d /tmp/notes /home/me/my repo" `shouldBe` Just (Binding (runId "0a1b2c3d") "/tmp/notes" "/home/me/my repo")

        it "reads no binding off a line that is no run line" $
            map parseBinding ["started 0a1b2c3d", "run 0a1b2c3d /tmp/notes", "run 0a1b2c3d  /top", "running 0a1b2c3d /n /t", ""]
                `shouldBe` replicate 5 Nothing

    describe "resolving the directory a hook runs the run in" $ do
        let binding = Binding (runId "0a1b2c3d") "/notes" "/child-work"
        it "is the bound worktree while it stands, for the session's agent and a subagent alike" $
            [resolve key (Just (binding, Standing)) "/work" | key <- [Main, AgentKey (AgentId "a1")]] `shouldBe` [Just "/child-work", Just "/child-work"]

        it "is none once the bound worktree is removed, never the session's own directory" $
            [resolve key (Just (binding, Removed)) "/work" | key <- [Main, AgentKey (AgentId "a1")]] `shouldBe` [Nothing, Nothing]

        it "is the session's own directory for its unbound agent" $
            resolve Main Nothing "/work" `shouldBe` Just "/work"

        it "is none for an unbound subagent, whose directory is its spawner's" $
            resolve (AgentKey (AgentId "a1")) Nothing "/work" `shouldBe` Nothing

    describe "a stale binding" $ do
        let binding = Binding (runId "0a1b2c3d") "/notes" "/work"
        it "is none while the worktree holds the bound run" $
            staleNote binding (runId "0a1b2c3d") `shouldBe` Nothing

        it "names both runs once the worktree holds another" $
            staleNote binding (runId "ffff0000")
                `shouldBe` Just "state: this agent is bound to run 0a1b2c3d, but /work holds run ffff0000 now; the hook recorded nothing\n"

    describe "a run's move to another worktree" $ do
        let binding = Binding (runId "0a1b2c3d") "/notes" "/work"
        it "rebinds a binding of the run at the old worktree to the new one, its notes kept" $
            rebound (runId "0a1b2c3d") "/work/" "/other" binding `shouldBe` Just binding {toplevel = "/other"}

        it "rebinds none of another run, or of the run at another worktree" $
            [rebound (runId "ffff0000") "/work" "/other" binding, rebound (runId "0a1b2c3d") "/elsewhere" "/other" binding] `shouldBe` [Nothing, Nothing]

    describe "the store" $ do
        it "lives under XDG_STATE_HOME, else HOME's .local/state, a relative one unset" $
            [storeRoot (Just "/xdg") (Just "/home/me"), storeRoot Nothing (Just "/home/me"), storeRoot (Just "rel") (Just "/home/me"), storeRoot Nothing Nothing]
                `shouldBe` [Just "/xdg/state/bindings", Just "/home/me/.local/state/state/bindings", Just "/home/me/.local/state/state/bindings", Nothing]

        it "keeps the run store beside the bindings, in one file" $
            [runStore (Just "/xdg") (Just "/home/me"), runStore Nothing (Just "/home/me"), runStore Nothing Nothing]
                `shouldBe` [Just "/xdg/state/kernel.db", Just "/home/me/.local/state/state/kernel.db", Nothing]

        it "keeps a session's agents and their stashed hand-backs side by side" $
            [(bindingFile <$> slotOf "/b" (SessionId "s1") key, stashFile <$> slotOf "/b" (SessionId "s1") key) | key <- [Main, AgentKey (AgentId "a1")]]
                `shouldBe` [(Just "/b/s1/main", Just "/b/s1/handback-main.json"), (Just "/b/s1/a1", Just "/b/s1/handback-a1.json")]

        it "writes nowhere outside the store for a session or agent id that is no file name" $
            [slotOf "/b" (SessionId session) key | (session, key) <- [("..", Main), ("s/../..", Main), ("", Main), ("s1", AgentKey (AgentId "../x")), ("s1", AgentKey (AgentId "."))]]
                `shouldBe` replicate 5 Nothing

{- | A binding init prints: its run id init's (no whitespace), a notes dir
init's parser takes (no whitespace), and any toplevel on one line.
-}
genBinding :: Gen Binding
genBinding =
    Binding
        <$> Gen.filter (not . Text.any isSpace . runIdText) genRunId
        <*> Gen.string (Range.linear 1 30) (Gen.filter (not . isSpace) Gen.unicode)
        <*> Gen.string (Range.linear 1 30) (Gen.filter (/= '\n') Gen.unicode)
