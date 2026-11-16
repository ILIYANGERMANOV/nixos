{- | @state-hook@'s events over the test doubles: the reply it prints, its
exit and the log it writes. The e2e specs prove the same over a real repo and
binary.
-}
module State.Cli.Shell.HookSpec (spec) where

import Data.Aeson (Value (..), decodeStrictText)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (for_)
import Data.IORef (IORef, modifyIORef')
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Doubles.FileSystem (Disk (..))
import State.Cli.Shell.World
import State.Protocol.Advice (Readiness (..))
import State.Run.Event (Branch (..), Envelope (..), runIdText)
import Test.Hspec (Spec, before, describe, expectationFailure, it, shouldBe, shouldReturn, shouldSatisfy)

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
                contextOf said `shouldSatisfy` maybe False ("step: gather" `Text.isInfixOf`)

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

            it "tells a disk failure before any run is found as context naming none, and still exits 0" $ \world -> do
                _ <- drive world []

                said <- hook world "resume" (sessionStartIn "/gone")

                said.code `shouldBe` 0
                contextOf said `shouldSatisfy` maybe False ("state hook resume: " `Text.isPrefixOf`)

            it "names the run of the session's own worktree in what resume, spawn and asked tell" $ \world -> do
                _ <- drive world []
                run <- runOf world
                _ <- succeeded =<< state world ["ask", "--kind", "Design", "which", "store?"]

                said <- traverse (uncurry (hook world)) [("resume", sessionStart), ("spawn", spawned "researcher"), ("asked", askedUser)]

                map contextOf said `shouldSatisfy` all (maybe False (("run " <> run <> ": ") `Text.isPrefixOf`))

            it "names the run of the session's own worktree on a log line it does not read" $ \world -> do
                _ <- drive world []
                run <- runOf world
                editLog world (<> "{\"v\":3,broken\n")

                said <- hook world "resume" sessionStart

                contextOf said `shouldSatisfy` maybe False (("run " <> run <> ": ") `Text.isPrefixOf`)

            it "names the run of the session's own worktree on a disk failure" $ \world -> do
                _ <- drive world []
                run <- runOf world
                unmount world notes

                said <- hook world "resume" sessionStart

                contextOf said `shouldSatisfy` maybe False (("run " <> run <> ": state hook resume: ") `Text.isPrefixOf`)

            it "is silent for a session bound to a worktree since removed" $ \world -> do
                _ <- drive world []
                run <- runOf world
                putFile world (bindings <> "/main") ("run " <> run <> " " <> Text.pack notes <> " /gone\n")
                before' <- logged world

                said <- hook world "resume" sessionStart

                after <- logged world
                (said.code, said.out, length after) `shouldBe` (0, [], length before')

        describe "handback" $ do
            it "records a hand-back seen twice once, telling what it recorded as context" $ \world -> do
                _ <- drive world (init toImplement)
                _ <- hook world "bind" (spawnResult "implementer")
                before' <- logged world
                run <- runOf world

                first <- hook world "handback" (handedBack "implementer")
                once <- logged world
                again <- hook world "handback" (handedBack "implementer")
                twice <- logged world

                first.code `shouldBe` 0
                contextOf first `shouldBe` Just ("run " <> run <> ": state: recorded 10 implement.done -> refactor\nstate: recorded 11 worker_returned -> refactor\n")
                first.out `shouldSatisfy` not . any (Text.isInfixOf "updatedInput")
                length once `shouldSatisfy` (> length before')
                (again.out, length twice) `shouldBe` ([], length once)

            it "leaves a child run's hand-back in the lead's worktree be" $ \world -> do
                _ <- drive world (init toImplement)
                before' <- logged world

                said <- hook world "handback" (handedBack "engineer")

                after <- logged world
                (said.code, said.out, length after) `shouldBe` (0, [], length before')

            it "is silent once the drafted PR is merged or closed" $ \world -> do
                _ <- drive world (init toImplement)
                _ <- hook world "bind" (spawnResult "implementer")
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
                _ <- drive world [Record ["fuel", "balanced"], Record ["gather.enough"], Planned]

                said <- hook world "spawn" (spawned "implementer")

                said.code `shouldBe` 0
                contextOf said `shouldSatisfy` maybe False ("state: the advice is SPAWN researcher, not implementer" `Text.isInfixOf`)

            it "records a researcher's spawn at the gather, and its hand-back, which lets the gather end" $ \world -> do
                _ <- drive world [Record ["fuel", "balanced"]]

                spawn <- hook world "spawn" (spawned "researcher")
                _ <- hook world "bind" (spawnResult "researcher")
                early <- state world ["record", "gather.enough"]
                back <- hook world "handback" (handedBack "researcher")
                enough <- state world ["record", "gather.enough"]

                (contextOf spawn, early.code, contextOf back, enough.code)
                    `shouldSatisfy` \case
                        (Just opened, 2, Just closed, 0) -> "recorded event 3 research.spawned -> gather" `Text.isInfixOf` opened && "recorded event 6 research.handed_back -> gather" `Text.isInfixOf` closed
                        _ -> False

            it "tells a recorded spawn's line, the researchers running and left, and to spawn more or wait, not the advice" $ \world -> do
                _ <- drive world [Record ["fuel", "balanced"]]
                _ <- hook world "spawn" (spawned "researcher")

                said <- hook world "spawn" (spawned "researcher")

                run <- runOf world
                contextOf said
                    `shouldBe` Just
                        ( Text.unlines
                            [ "run " <> run <> ": recorded event 4 research.spawned -> gather"
                            , "  researchers: 2 running, 3 of 5 left"
                            , "  next: spawn more, or end your turn until they hand back"
                            ]
                        )

            it "tells a spawn that spends the researchers' budget only to wait for the one running" $ \world -> do
                _ <- drive world [Record ["fuel", "low"]]

                said <- hook world "spawn" (spawned "researcher")

                run <- runOf world
                contextOf said
                    `shouldBe` Just
                        ( Text.unlines
                            [ "run " <> run <> ": recorded event 3 research.spawned -> gather"
                            , "  researchers: 1 running, none of 1 left"
                            , "  next: end your turn until it hands back"
                            ]
                        )

            it "tells a researcher's hand-back with another still running to wait for it" $ \world -> do
                _ <- drive world [Record ["fuel", "balanced"]]
                _ <- hook world "spawn" (spawned "researcher")
                _ <- hook world "spawn" (spawned "researcher")
                _ <- hook world "bind" (spawnResult "researcher")

                said <- hook world "handback" (handedBack "researcher")

                run <- runOf world
                contextOf said
                    `shouldBe` Just
                        ( Text.unlines
                            [ "run " <> run <> ": recorded event 6 research.handed_back -> gather"
                            , "  researchers: 1 running, 3 of 5 left"
                            , "  next: end your turn until it hands back"
                            , "state: recorded 7 worker_returned -> gather"
                            ]
                        )

            it "tells the last researcher's hand-back to ask state next" $ \world -> do
                _ <- drive world [Record ["fuel", "balanced"]]
                _ <- hook world "spawn" (spawned "researcher")
                _ <- hook world "bind" (spawnResult "researcher")

                said <- hook world "handback" (handedBack "researcher")

                run <- runOf world
                contextOf said
                    `shouldBe` Just
                        ( Text.unlines
                            [ "run " <> run <> ": recorded event 5 research.handed_back -> gather"
                            , "  researchers: none running, 4 of 5 left"
                            , "  next: state next"
                            , "state: recorded 6 worker_returned -> gather"
                            ]
                        )

            it "opens no child for a spawn past the researchers' cap, and tells the refusal" $ \world -> do
                _ <- drive world [Record ["fuel", "low"]]
                _ <- hook world "spawn" (spawned "researcher")

                said <- hook world "spawn" (spawned "researcher")

                said.code `shouldBe` 0
                contextOf said `shouldSatisfy` maybe False ("Researchers allows 1" `Text.isInfixOf`)
                loggedEvents world `shouldReturn` ["started", "fuel", "research.spawned"]

            it "records nothing on a spawn of a role whose step opens no child" $ \world -> do
                _ <- drive world [Record ["fuel", "balanced"]]

                _ <- hook world "spawn" (spawned "implementer")

                loggedEvents world `shouldReturn` ["started", "fuel"]

            it "leaves a researcher's hand-back off the gather to the lead, logging only that it returned" $ \world -> do
                _ <- drive world [Record ["fuel", "balanced"], Record ["gather.enough"]]
                _ <- hook world "bind" (spawnResult "researcher")

                said <- hook world "handback" (handedBack "researcher")

                (said.code, said.out) `shouldBe` (0, [])
                loggedEvents world `shouldReturn` ["started", "fuel", "gather.enough", "worker_spawned", "worker_returned"]

        describe "bind" $ do
            it "leaves an unbound worker's hand-back unrecorded until its spawner's hook binds it, then records it once" $ \world -> do
                _ <- drive world (init toImplement)
                before' <- logged world

                early <- hook world "handback" (handedBack "implementer")
                unbound <- logged world
                bound <- hook world "bind" (spawnResult "implementer")
                once <- logged world
                again <- hook world "bind" (spawnResult "implementer")
                twice <- logged world

                (early.code, early.out, length unbound) `shouldBe` (0, [], length before')
                contextOf bound `shouldSatisfy` maybe False ("state: recorded 10 implement.done -> refactor\nstate: recorded 11 worker_returned -> refactor" `Text.isInfixOf`)
                (length once, length twice) `shouldBe` (length before' + 3, length once)
                contextOf again `shouldSatisfy` maybe False (not . Text.isInfixOf "recorded")

            it "records a worker's hand-back made after its spawner's hook bound it" $ \world -> do
                _ <- drive world (init toImplement)
                run <- runOf world

                bound <- hook world "bind" (spawnResult "implementer")
                back <- hook world "handback" (handedBack "implementer")

                contextOf bound `shouldBe` Just ("run " <> run <> ": state: implementer a1 works in this run\n")
                contextOf back `shouldBe` Just ("run " <> run <> ": state: recorded 10 implement.done -> refactor\nstate: recorded 11 worker_returned -> refactor\n")

            it "binds no subagent no flow knows, whose hand-back stays its own" $ \world -> do
                _ <- drive world (init toImplement)

                said <- hook world "bind" (spawnResult "Explore")

                (said.code, said.out) `shouldBe` (0, [])

            it "records nothing for a worker bound to a run its worktree no longer holds, and says so" $ \world -> do
                _ <- drive world [Record ["fuel", "balanced"]]
                old <- runOf world
                _ <- hook world "bind" (spawnResult "researcher")
                _ <- succeeded =<< state world ["stop", "blocked", "moved", "on"]
                _ <- succeeded =<< state world ["init", "--notes", "/notes2"]
                _ <- hook world "spawn" (spawned "researcher")
                before' <- logged world

                said <- hook world "handback" (handedBack "researcher")

                contextOf said `shouldSatisfy` maybe False (("bound to run " <> old <> ", but /work holds run ") `Text.isInfixOf`)
                (length <$> logged world) `shouldReturn` length before'

            it "names the run when it removes a stashed hand-back that is no step's" $ \world -> do
                _ <- drive world (init toImplement)
                run <- runOf world
                let stash = bindings <> "/handback-a1.json"
                putFile world stash "{}"

                said <- hook world "bind" (spawnResult "implementer")

                contextOf said
                    `shouldBe` Just
                        ( Text.concat
                            [ "run " <> run <> ": state: implementer a1 works in this run\n"
                            , "run " <> run <> ": state: the hand-back stashed at " <> Text.pack stash <> " is no hand-back of a step; removed\n"
                            ]
                        )

            it "names the run a bound worker's hand-back failed at, on a log line it does not read" $ \world -> do
                _ <- drive world (init toImplement)
                run <- runOf world
                _ <- hook world "bind" (spawnResult "implementer")
                editLog world (<> "{\"v\":3,broken\n")

                said <- hook world "handback" (handedBack "implementer")

                contextOf said `shouldSatisfy` maybe False (("run " <> run <> ": ") `Text.isPrefixOf`)

            it "names the run a bound worker's hand-back failed at, on a disk failure" $ \world -> do
                _ <- drive world (init toImplement)
                run <- runOf world
                _ <- hook world "bind" (spawnResult "implementer")
                unmount world notes

                said <- hook world "handback" (handedBack "implementer")

                contextOf said `shouldSatisfy` maybe False (("run " <> run <> ": state hook handback: ") `Text.isPrefixOf`)

            it "names the spawner's run a stashed hand-back failed at, on a disk failure" $ \world -> do
                _ <- drive world (init toImplement)
                run <- runOf world
                _ <- hook world "handback" (handedBack "implementer")
                unmount world notes

                said <- hook world "bind" (spawnResult "implementer")

                contextOf said `shouldSatisfy` maybe False (("run " <> run <> ": state hook bind: ") `Text.isInfixOf`)

            it "names a bound spawner's run when it binds its worker" $ \world -> do
                _ <- drive world (init toImplement)
                run <- runOf world
                putFile world (bindings <> "/main") ("run " <> run <> " " <> Text.pack notes <> " /work\n")

                said <- hook world "bind" (spawnResult "implementer")

                contextOf said `shouldBe` Just ("run " <> run <> ": state: implementer a1 works in this run\n")

            it "binds no worker for a spawner bound to a worktree since removed, and stays silent" $ \world -> do
                _ <- drive world (init toImplement)
                run <- runOf world
                putFile world (bindings <> "/main") ("run " <> run <> " " <> Text.pack notes <> " /gone\n")

                said <- hook world "bind" (spawnResult "implementer")

                (said.code, said.out) `shouldBe` (0, [])

            it "tells a git that cannot start as context naming the run, never as a removed worktree" $ \world -> do
                _ <- drive world (init toImplement)
                run <- runOf world
                _ <- hook world "bind" (spawnResult "implementer")
                modifyIORef' world (\w -> w {gitOnPath = False})

                said <- hook world "handback" (handedBack "implementer")

                contextOf said `shouldSatisfy` maybe False (("run " <> run <> ": state hook handback: ") `Text.isPrefixOf`)

            it "records nothing and stays silent for a worker bound to a worktree since removed" $ \world -> do
                _ <- drive world (init toImplement)
                run <- runOf world
                putFile world (bindings <> "/a1") ("run " <> run <> " " <> Text.pack notes <> " /gone\n")
                before' <- logged world

                said <- hook world "handback" (handedBack "implementer")

                after <- logged world
                (said.code, said.out, length after) `shouldBe` (0, [], length before')

        describe "route" $ do
            it "denies a bound session's state call at another run, naming its own" $ \world -> do
                run <- startedRun world
                putFile world (bindings <> "/main") ("run " <> run <> " " <> Text.pack notes <> " /other\n")
                modifyIORef' world (\w -> w {disk = w.disk {dirs = Set.insert "/other" w.disk.dirs}})

                said <- succeeded =<< hook world "route" (stateCall "state next")

                said `shouldSatisfy` any (Text.isInfixOf ("bound to run " <> run))

            it "is silent for a session bound to a worktree since removed" $ \world -> do
                run <- startedRun world
                putFile world (bindings <> "/main") ("run " <> run <> " " <> Text.pack notes <> " /gone\n")

                said <- succeeded =<< hook world "route" (stateCall "state next")

                said `shouldBe` []

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

            it "exits 2 on a hook name it does not know, printing its help" $ \world -> do
                said <- hook world "nowhere" sessionStart

                (said.code, take 1 said.err) `shouldBe` (2, ["Invalid argument `nowhere'"])
                said.err `shouldSatisfy` elem "Usage: state-hook COMMAND"

            it "exits 2 at an event its hook does not run at" $ \world -> do
                said <- hook world "resume" askedUser

                (said.code, said.err) `shouldBe` (2, ["state-hook resume does not run at afterTool"])

            it "appends nothing on bad usage" $ \world -> do
                _ <- drive world []
                before' <- logBytes world

                _ <- hook world "handback" "not json"

                after <- logBytes world
                after `shouldBe` before'

-- | The id of the run the worktree's log holds.
runOf :: IORef World -> IO Text
runOf world =
    logged world >>= \case
        first : _ -> pure (runIdText first.run)
        [] -> "" <$ expectationFailure "no run logged"

-- | The @context@ of the reply printed, if any.
contextOf :: Ran -> Maybe Text
contextOf said = case decodeStrictText (Text.concat said.out) of
    Just (Object reply) | Just (String context) <- KeyMap.lookup "context" reply -> Just context
    _ -> Nothing

{- | A directory gone from under the files in it, as when a disk unmounts:
they still read, but nothing writes there.
-}
unmount :: IORef World -> FilePath -> IO ()
unmount world dir = modifyIORef' world (\w -> w {disk = w.disk {dirs = Set.delete dir w.disk.dirs}})

-- | Session @s1@'s bindings, under the world's @HOME@.
bindings :: FilePath
bindings = "/home/.local/state/state/bindings/s1"
