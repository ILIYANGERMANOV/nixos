{- | @state-hook@'s events over the test doubles: the reply it prints, its
exit and the log it writes. The e2e specs prove the same over a real repo and
binary.
-}
module State.Shell.HookSpec (spec) where

import Data.Aeson (Value (..), decodeStrictText)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (for_)
import Data.IORef (modifyIORef')
import Data.Text (Text)
import Data.Text qualified as Text
import State.Advice (Readiness (..))
import State.Event (Branch (..))
import State.Shell.World
import Test.Hspec (Spec, before, describe, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = describe "state-hook over the doubles" $ do
    before newWorld $ do
        describe "resume" $ do
            it "is silent in a worktree with no run" $ \world -> do
                said <- hook world "resume" sessionStart

                (said.code, said.out, said.err) `shouldBe` (0, [], [])

            it "tells a resumed session where its run stands" $ \world -> do
                _ <- drive world []

                said <- hook world "resume" sessionStart

                (said.code, said.err) `shouldBe` (0, [])
                contextOf said `shouldSatisfy` maybe False ("step: research" `Text.isInfixOf`)

            it "is silent off the branch the draft PR bound the run to" $ \world -> do
                _ <- drive world (init toImplement)
                modifyIORef' world (\w -> w {branch = Just (Branch "other")})

                said <- succeeded =<< hook world "resume" sessionStart

                said `shouldBe` []

            it "is silent on a log it does not read" $ \world -> do
                _ <- startedRun world
                editLog world (const "{\"seq\":0,\"ts\":\"t\",\"head\":null,\"session\":null,\"event\":{\"type\":\"started\",\"notes\":\"n\",\"version\":2}}\n")

                said <- succeeded =<< hook world "resume" sessionStart

                said `shouldBe` []

            it "tells a log line it does not read, as context" $ \world -> do
                _ <- drive world []
                editLog world (<> "{\"v\":3,broken\n")

                said <- hook world "resume" sessionStart

                said.code `shouldBe` 0
                contextOf said `shouldSatisfy` maybe False ("line 2 is not read" `Text.isInfixOf`)

            it "tells a disk failure as context and still exits 0" $ \world -> do
                _ <- drive world []

                said <- hook world "resume" (sessionStartIn "/gone")

                said.code `shouldBe` 0
                contextOf said `shouldSatisfy` maybe False ("state hook resume: " `Text.isPrefixOf`)

        describe "handback" $ do
            it "records a hand-back seen twice once, appending what it recorded" $ \world -> do
                _ <- drive world (init toImplement)
                before' <- logged world

                first <- hook world "handback" (handedBack "implementer")
                once <- logged world
                again <- hook world "handback" (handedBack "implementer")
                twice <- logged world

                first.code `shouldBe` 0
                messageOf first `shouldBe` Just "READY\nDone.\n\n\nstate: recorded 9 implement.done -> refactor\n"
                length once `shouldSatisfy` (> length before')
                (again.out, length twice) `shouldBe` ([], length once)

            it "is silent once the drafted PR is merged or closed" $ \world -> do
                _ <- drive world (init toImplement)
                before' <- logged world

                for_ [IsMerged, IsClosed] $ \over -> do
                    modifyIORef' world (\w -> w {pr = draftPr over})
                    resumed <- succeeded =<< hook world "resume" sessionStart
                    handed <- succeeded =<< hook world "handback" (handedBack "implementer")
                    (resumed, handed) `shouldBe` ([], [])

                after <- logged world
                length after `shouldBe` length before'

        describe "spawn" $ do
            it "warns the lead spawning a role off the advice" $ \world -> do
                _ <- drive world [Record ["quality", "Balanced"], Record ["size", "Normal"]]

                said <- hook world "spawn" (spawned "implementer")

                said.code `shouldBe` 0
                contextOf said `shouldSatisfy` maybe False ("state: the advice is SPAWN researcher, not implementer" `Text.isInfixOf`)

        describe "asked" $ do
            it "tells the lead how to record the answer to a question put to the user" $ \world -> do
                _ <- drive world []
                [asked, _] <- succeeded =<< state world ["ask", "--kind", "Design", "which", "store?"]
                let qid = Text.drop (Text.length "asked ") asked

                said <- hook world "asked" askedUser

                contextOf said `shouldSatisfy` maybe False (("state answer " <> qid <> " <answer>") `Text.isInfixOf`)

        describe "usage" $ do
            it "exits 2 on stdin that is no hook event" $ \world -> do
                said <- hook world "resume" "not json"

                said.code `shouldBe` 2
                take 1 said.err `shouldSatisfy` all ("state-hook resume: " `Text.isPrefixOf`)

            it "exits 2 on a hook name it does not know, naming the hooks" $ \world -> do
                said <- hook world "nowhere" sessionStart

                (said.code, said.err) `shouldBe` (2, ["usage: state-hook resume | spawn | handback | asked"])

            it "exits 2 at an event its hook does not run at" $ \world -> do
                said <- hook world "resume" askedUser

                (said.code, said.err) `shouldBe` (2, ["state-hook resume does not run at afterTool"])

            it "appends nothing on bad usage" $ \world -> do
                _ <- drive world []
                before' <- logBytes world

                _ <- hook world "handback" "not json"

                after <- logBytes world
                after `shouldBe` before'

-- | The @context@ of the reply printed, if any.
contextOf :: Ran -> Maybe Text
contextOf said = case decodeStrictText (Text.concat said.out) of
    Just (Object reply) | Just (String context) <- KeyMap.lookup "context" reply -> Just context
    _ -> Nothing

-- | The hand-back message of an @allow@ reply that updates the tool's input.
messageOf :: Ran -> Maybe Text
messageOf said = case decodeStrictText (Text.concat said.out) of
    Just (Object reply)
        | Just (Object input) <- KeyMap.lookup "updatedInput" reply
        , Just (String message) <- KeyMap.lookup "message" input ->
            Just message
    _ -> Nothing
