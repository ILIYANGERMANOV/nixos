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
import State.Run.Event (Branch (..))
import Test.Hspec (Spec, before, describe, it, shouldBe, shouldContain, shouldReturn, shouldSatisfy)

spec :: Spec
spec = describe "state-hook over the doubles" $ do
    before newWorld $ do
        describe "resume" $ do
            it "is silent in a worktree with no run" $ \world -> do
                said <- hook world "resume" sessionStart

                (said.code, said.out, said.err) `shouldBe` (0, [], [])

            it "tells a resumed session where its run stands" $ \world -> do
                _ <- drive world [Record ["fuel.set", "balanced"]]

                said <- hook world "resume" sessionStart

                (said.code, said.err) `shouldBe` (0, [])
                contextOf said `shouldSatisfy` maybe False ("step: gather" `Text.isInfixOf`)

            it "is silent off the branch the draft PR bound the run to" $ \world -> do
                _ <- drive world (Record ["fuel.set", "balanced"] : init toImplement)
                modifyIORef' world (\w -> w {branch = Just (Branch "other")})

                said <- succeeded =<< hook world "resume" sessionStart

                said `shouldBe` []

            it "is silent on a log of another version, as only a spawn or a hand-back is lost there" $ \world -> do
                _ <- startedRun world
                editLog world (const ["{\"seq\":0,\"ts\":\"t\",\"head\":null,\"session\":null,\"event\":{\"type\":\"started\",\"notes\":\"n\",\"version\":2}}"])

                said <- succeeded =<< hook world "resume" sessionStart

                said `shouldBe` []

            it "tells a log line it does not read, as context" $ \world -> do
                _ <- drive world []
                editLog world (<> ["{\"v\":3,broken"])

                said <- hook world "resume" sessionStart

                said.code `shouldBe` 0
                contextOf said `shouldSatisfy` maybe False ("event 2 is not read" `Text.isInfixOf`)

            it "tells a disk failure before any run is found as context naming none, and still exits 0" $ \world -> do
                _ <- drive world [Record ["fuel.set", "balanced"]]

                said <- hook world "resume" (sessionStartIn "/gone")

                said.code `shouldBe` 0
                contextOf said `shouldSatisfy` maybe False ("state hook resume: " `Text.isPrefixOf`)

            it "names the run of the session's own worktree in what resume, spawn and asked tell" $ \world -> do
                _ <- drive world [Record ["fuel.set", "balanced"]]
                run <- runOf world
                _ <- succeeded =<< state world ["ask", "--kind", "Design", "which", "store?"]

                said <- traverse (uncurry (hook world)) [("resume", sessionStart), ("spawn", spawned "researcher"), ("asked", askedUser)]

                map contextOf said `shouldSatisfy` all (maybe False (("run " <> run <> ": ") `Text.isPrefixOf`))

            it "names the run of the session's own worktree on a log line it does not read" $ \world -> do
                _ <- drive world [Record ["fuel.set", "balanced"]]
                run <- runOf world
                editLog world (<> ["{\"v\":3,broken"])

                said <- hook world "resume" sessionStart

                contextOf said `shouldSatisfy` maybe False (("run " <> run <> ": ") `Text.isPrefixOf`)

            it "names the run of the session's own worktree on a disk failure" $ \world -> do
                _ <- drive world [Record ["fuel.set", "balanced"]]
                run <- runOf world
                storeDown world

                said <- hook world "resume" sessionStart

                contextOf said `shouldSatisfy` maybe False (("run " <> run <> ": state hook resume: ") `Text.isPrefixOf`)

            it "is silent for a session bound to a worktree since removed" $ \world -> do
                _ <- drive world [Record ["fuel.set", "balanced"]]
                run <- runOf world
                putFile world (bindings <> "/main") ("run " <> run <> " " <> Text.pack notes <> " /gone\n")
                before' <- logged world

                said <- hook world "resume" sessionStart

                after <- logged world
                (said.code, said.out, length after) `shouldBe` (0, [], length before')

        describe "handback" $ do
            it "records a hand-back seen twice once, telling what it recorded as context" $ \world -> do
                _ <- drive world (Record ["fuel.set", "balanced"] : init toImplement)
                _ <- hook world "bind" (spawnResult "implementer")
                before' <- logged world
                run <- runOf world

                first <- hook world "handback" (handedBack "implementer")
                once <- logged world
                again <- hook world "handback" (handedBack "implementer")
                twice <- logged world

                first.code `shouldBe` 0
                contextOf first `shouldBe` Just ("run " <> run <> ": state: recorded 14 implement.done -> skip_refactor\nstate: recorded 15 worker_returned -> skip_refactor\n")
                first.out `shouldSatisfy` not . any (Text.isInfixOf "updatedInput")
                length once `shouldSatisfy` (> length before')
                (again.out, length twice) `shouldBe` ([], length once)

            it "leaves a child run's hand-back in the lead's worktree be" $ \world -> do
                _ <- drive world (Record ["fuel.set", "balanced"] : init toImplement)
                before' <- logged world

                said <- hook world "handback" (handedBack "engineer")

                after <- logged world
                (said.code, said.out, length after) `shouldBe` (0, [], length before')

            it "is silent once the drafted PR is merged or closed" $ \world -> do
                _ <- drive world (Record ["fuel.set", "balanced"] : init toImplement)
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
            it "names the record by hand on a log of another version, as it records nothing there" $ \world -> do
                _ <- startedRun world
                editLog world (const ["{\"seq\":0,\"ts\":\"t\",\"head\":null,\"session\":null,\"event\":{\"type\":\"started\",\"notes\":\"n\",\"version\":2}}"])

                said <- hook world "spawn" (spawned "researcher")

                said.code `shouldBe` 0
                contextOf said `shouldSatisfy` maybe False ("state handback <role>" `Text.isInfixOf`)

            it "warns the lead spawning a role off the advice" $ \world -> do
                _ <- drive world ([Record ["fuel.set", "balanced"]] <> gathered <> [Planned])

                said <- hook world "spawn" (spawned "implementer")

                said.code `shouldBe` 0
                contextOf said `shouldSatisfy` maybe False ("state: the advice is SPAWN researcher, not implementer" `Text.isInfixOf`)

            it "records a researcher's spawn at its research state, and its hand-back and return, which moves the waiting gather on to its notes" $ \world -> do
                _ <- drive world researching

                spawn <- hook world "spawn" (spawned "researcher")
                _ <- hook world "bind" (spawnResult "researcher")
                enough <- state world ["record", "gather.enough"]
                back <- hook world "handback" (handedBack "researcher")

                (contextOf spawn, enough.code, contextOf back)
                    `shouldSatisfy` \case
                        (Just opened, 0, Just closed) -> "recorded event 4 gather/research.spawned -> gather" `Text.isInfixOf` opened && "recorded event 7 gather/research.handed_back -> gather/researchers" `Text.isInfixOf` closed && "recorded 8 worker_returned -> gather/notes" `Text.isInfixOf` closed
                        _ -> False

            it "gives a researcher whose spawn led back to the gather's pick the research section of its brief alone" $ \world -> do
                _ <- drive world researching
                _ <- hook world "spawn" (spawned "researcher")
                section <- succeeded =<< state world ["brief", "researcher", "--section", "research"]

                said <- hook world "begin" (agentStarted "researcher")

                contextOf said `shouldBe` Just (Text.unlines section)

            it "tells a recorded spawn's line, the researchers left, and the pick to record before each more spawn, not the advice" $ \world -> do
                _ <- drive world researching
                first <- hook world "spawn" (spawned "researcher")
                _ <- state world ["record", "gather.research"]

                said <- hook world "spawn" (spawned "researcher")

                run <- runOf world
                (contextOf first, contextOf said)
                    `shouldBe` ( Just
                                    ( Text.unlines
                                        [ "run " <> run <> ": recorded event 4 gather/research.spawned -> gather"
                                        , "  researchers: 4 of 5 left"
                                        , "  next: for each more, `state record gather.research`, then spawn it in a message of its own; or end your turn until they hand back"
                                        ]
                                    )
                               , Just
                                    ( Text.unlines
                                        [ "run " <> run <> ": recorded event 6 gather/research.spawned -> gather"
                                        , "  researchers: 3 of 5 left"
                                        , "  next: for each more, `state record gather.research`, then spawn it in a message of its own; or end your turn until they hand back"
                                        ]
                                    )
                               )

            it "tells a spawn that spends the researchers' budget only to wait" $ \world -> do
                _ <- drive world [Record ["fuel.set", "low"], Record ["gather.research"]]

                said <- hook world "spawn" (spawned "researcher")

                run <- runOf world
                contextOf said
                    `shouldBe` Just
                        ( Text.unlines
                            [ "run " <> run <> ": recorded event 4 gather/research.spawned -> gather"
                            , "  researchers: none of 1 left"
                            , "  next: end your turn until they hand back"
                            ]
                        )

            it "tells a researcher's hand-back with another still running to wait for it" $ \world -> do
                _ <- drive world researching
                _ <- hook world "spawn" (spawned "researcher")
                _ <- hook world "bind" (spawnResultOf "researcher" "a0")
                _ <- state world ["record", "gather.research"]
                _ <- hook world "spawn" (spawned "researcher")
                _ <- hook world "bind" (spawnResult "researcher")

                said <- hook world "handback" (handedBack "researcher")

                run <- runOf world
                contextOf said
                    `shouldBe` Just
                        ( Text.unlines
                            [ "run " <> run <> ": recorded event 9 gather/research.handed_back -> gather"
                            , "  researchers: 1 running, 3 of 5 left"
                            , "  next: end your turn until it hands back"
                            , "state: recorded 10 worker_returned -> gather"
                            ]
                        )

            it "tells the last researcher's hand-back to ask state next" $ \world -> do
                _ <- drive world researching
                _ <- hook world "spawn" (spawned "researcher")
                _ <- hook world "bind" (spawnResult "researcher")

                said <- hook world "handback" (handedBack "researcher")

                run <- runOf world
                contextOf said
                    `shouldBe` Just
                        ( Text.unlines
                            [ "run " <> run <> ": recorded event 6 gather/research.handed_back -> gather"
                            , "  researchers: none running, 4 of 5 left"
                            , "  next: state next"
                            , "state: recorded 7 worker_returned -> gather"
                            ]
                        )

            it "opens no child for a spawn past the researchers' cap, and tells the refusal" $ \world -> do
                _ <- drive world [Record ["fuel.set", "low"], Record ["gather.research"]]
                _ <- hook world "spawn" (spawned "researcher")
                picked <- state world ["record", "gather.research"]

                said <- hook world "spawn" (spawned "researcher")

                (picked.code, said.code) `shouldBe` (2, 0)
                contextOf said `shouldSatisfy` maybe False ("Researchers allows 1" `Text.isInfixOf`)
                loggedEvents world `shouldReturn` ["started", "fuel.set", "gather.research", "gather/research.spawned", "refused"]

            it "records nothing on a spawn of a role whose step opens no child" $ \world -> do
                _ <- drive world [Record ["fuel.set", "balanced"]]

                _ <- hook world "spawn" (spawned "implementer")

                loggedEvents world `shouldReturn` ["started", "fuel.set"]

            it "leaves a researcher's hand-back off the gather to the lead, logging only that it returned" $ \world -> do
                _ <- drive world (Record ["fuel.set", "balanced"] : gathered)
                _ <- hook world "bind" (spawnResult "researcher")

                said <- hook world "handback" (handedBack "researcher")

                (said.code, said.out) `shouldBe` (0, [])
                loggedEvents world `shouldReturn` ["started", "fuel.set", "gather.enough", "gather/notes.done", "worker_spawned", "worker_returned"]

        describe "bind" $ do
            it "leaves an unbound worker's hand-back unrecorded until its spawner's hook binds it, then records it once" $ \world -> do
                _ <- drive world (Record ["fuel.set", "balanced"] : init toImplement)
                before' <- logged world

                early <- hook world "handback" (handedBack "implementer")
                unbound <- logged world
                bound <- hook world "bind" (spawnResult "implementer")
                once <- logged world
                again <- hook world "bind" (spawnResult "implementer")
                twice <- logged world

                (early.code, early.out, length unbound) `shouldBe` (0, [], length before')
                contextOf bound `shouldSatisfy` maybe False ("state: recorded 14 implement.done -> skip_refactor\nstate: recorded 15 worker_returned -> skip_refactor" `Text.isInfixOf`)
                (length once, length twice) `shouldBe` (length before' + 3, length once)
                contextOf again `shouldSatisfy` maybe False (not . Text.isInfixOf "recorded")

            it "records a worker's hand-back made after its spawner's hook bound it" $ \world -> do
                _ <- drive world (Record ["fuel.set", "balanced"] : init toImplement)
                run <- runOf world

                bound <- hook world "bind" (spawnResult "implementer")
                back <- hook world "handback" (handedBack "implementer")

                contextOf bound `shouldBe` Just ("run " <> run <> ": state: implementer a1 works in this run\n")
                contextOf back `shouldBe` Just ("run " <> run <> ": state: recorded 14 implement.done -> skip_refactor\nstate: recorded 15 worker_returned -> skip_refactor\n")

            it "binds no subagent no flow knows, whose hand-back stays its own" $ \world -> do
                _ <- drive world (Record ["fuel.set", "balanced"] : init toImplement)

                said <- hook world "bind" (spawnResult "Explore")

                (said.code, said.out) `shouldBe` (0, [])

            it "records nothing for a worker bound to a run its worktree no longer holds, and says so" $ \world -> do
                _ <- drive world [Record ["fuel.set", "balanced"]]
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
                _ <- drive world (Record ["fuel.set", "balanced"] : init toImplement)
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
                _ <- drive world (Record ["fuel.set", "balanced"] : init toImplement)
                run <- runOf world
                _ <- hook world "bind" (spawnResult "implementer")
                editLog world (<> ["{\"v\":3,broken"])

                said <- hook world "handback" (handedBack "implementer")

                contextOf said `shouldSatisfy` maybe False (("run " <> run <> ": ") `Text.isPrefixOf`)

            it "names the run a bound worker's hand-back failed at, on a disk failure" $ \world -> do
                _ <- drive world (Record ["fuel.set", "balanced"] : init toImplement)
                run <- runOf world
                _ <- hook world "bind" (spawnResult "implementer")
                storeDown world

                said <- hook world "handback" (handedBack "implementer")

                contextOf said `shouldSatisfy` maybe False (("run " <> run <> ": state hook handback: ") `Text.isPrefixOf`)

            it "names the spawner's run a stashed hand-back failed at, on a disk failure" $ \world -> do
                _ <- drive world (Record ["fuel.set", "balanced"] : init toImplement)
                run <- runOf world
                _ <- hook world "handback" (handedBack "implementer")
                storeDown world

                said <- hook world "bind" (spawnResult "implementer")

                contextOf said `shouldSatisfy` maybe False (("run " <> run <> ": state hook bind: ") `Text.isInfixOf`)

            it "names a bound spawner's run when it binds its worker" $ \world -> do
                _ <- drive world (Record ["fuel.set", "balanced"] : init toImplement)
                run <- runOf world
                putFile world (bindings <> "/main") ("run " <> run <> " " <> Text.pack notes <> " /work\n")

                said <- hook world "bind" (spawnResult "implementer")

                contextOf said `shouldBe` Just ("run " <> run <> ": state: implementer a1 works in this run\n")

            it "binds no worker for a spawner bound to a worktree since removed, and stays silent" $ \world -> do
                _ <- drive world (Record ["fuel.set", "balanced"] : init toImplement)
                run <- runOf world
                putFile world (bindings <> "/main") ("run " <> run <> " " <> Text.pack notes <> " /gone\n")

                said <- hook world "bind" (spawnResult "implementer")

                (said.code, said.out) `shouldBe` (0, [])

            it "tells a git that cannot start as context naming the run, never as a removed worktree" $ \world -> do
                _ <- drive world (Record ["fuel.set", "balanced"] : init toImplement)
                run <- runOf world
                _ <- hook world "bind" (spawnResult "implementer")
                modifyIORef' world (\w -> w {gitOnPath = False})

                said <- hook world "handback" (handedBack "implementer")

                contextOf said `shouldSatisfy` maybe False (("run " <> run <> ": state hook handback: ") `Text.isPrefixOf`)

            it "records nothing and stays silent for a worker bound to a worktree since removed" $ \world -> do
                _ <- drive world (Record ["fuel.set", "balanced"] : init toImplement)
                run <- runOf world
                putFile world (bindings <> "/a1") ("run " <> run <> " " <> Text.pack notes <> " /gone\n")
                before' <- logged world

                said <- hook world "handback" (handedBack "implementer")

                after <- logged world
                (said.code, said.out, length after) `shouldBe` (0, [], length before')

        describe "route" $ do
            it "denies a session bound to an architect run its edit, commit, push and PR, letting a spawn, gh issue and a heredoc through" $ \world -> do
                run <- startedIn world ["--flow", "architect"]
                putFile world (bindings <> "/main") ("run " <> run <> " " <> Text.pack notes <> " /work\n")

                let denied = editCall : map stateCall writing
                    allowed = spawned "researcher" : map stateCall issuing
                said <- traverse (fmap denies . hook world "route") (denied <> allowed)

                said `shouldBe` map (const True) denied <> map (const False) allowed

            it "lets a session bound to an engineer run edit, commit and push" $ \world -> do
                run <- startedRun world
                putFile world (bindings <> "/main") ("run " <> run <> " " <> Text.pack notes <> " /work\n")

                said <- traverse (hook world "route") (editCall : map stateCall writing)

                map (.out) said `shouldBe` map (const []) (editCall : map stateCall writing)

            it "denies a session bound to a chief run in its discussion or architect branch its edit, commit, push and PR, letting a spawn and a heredoc through" $ \_ ->
                for_ ["route.discussion", "route.architect"] $ \branch -> do
                    world <- newWorld
                    run <- startedIn world ["--flow", "chief"]
                    _ <- succeeded =<< state world ["record", "fuel.set", "balanced"]
                    _ <- succeeded =<< state world ["record", branch]
                    putFile world (bindings <> "/main") ("run " <> run <> " " <> Text.pack notes <> " /work\n")

                    let denied = editCall : map stateCall writing
                        allowed = spawned "researcher" : map stateCall issuing
                    said <- traverse (fmap denies . hook world "route") (denied <> allowed)

                    said `shouldBe` map (const True) denied <> map (const False) allowed

            it "lets a session bound to a chief run edit, commit and push at its Fuel, its hub and in its engineer, 10x, blocks or other branch" $ \_ ->
                for_ [[], [["fuel.set", "balanced"]], [["fuel.set", "balanced"], ["route.engineer"]], [["fuel.set", "balanced"], ["route.10x"]], [["fuel.set", "balanced"], ["route.blocks"]], [["fuel.set", "balanced"], ["route.other"]]] $ \picks -> do
                    world <- newWorld
                    run <- startedIn world ["--flow", "chief"]
                    for_ picks $ \pick -> succeeded =<< state world ("record" : pick)
                    putFile world (bindings <> "/main") ("run " <> run <> " " <> Text.pack notes <> " /work\n")

                    said <- traverse (hook world "route") (editCall : map stateCall writing)

                    map (.out) said `shouldBe` map (const []) (editCall : map stateCall writing)

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
                _ <- drive world [Record ["fuel.set", "balanced"]]
                [asked, _] <- succeeded =<< state world ["ask", "--kind", "Design", "which", "store?"]
                let qid = Text.drop (Text.length "asked ") asked

                said <- hook world "asked" askedUser

                contextOf said `shouldSatisfy` maybe False (("state answer " <> qid <> " <answer>") `Text.isInfixOf`)

        describe "stop" $ do
            it "records a child run's agent ended with no hand-back once, at its stop and its spawner's stop call, saying nothing" $ \world -> do
                _ <- engineerAtWork world

                stopped <- hook world "stop" (agentStop "engineer" "e1" ["e1"])
                called <- hook world "stop" (stopCall "e1")

                (stopped.code, stopped.out, called.code, called.out) `shouldBe` (0, [], 0, [])
                filter (== "agent_ended") <$> loggedEventsIn world "/child" `shouldReturn` ["agent_ended"]

            it "lists a child whose agent stopped with no hand-back, with its resume step" $ \world -> do
                child <- engineerAtWork world
                _ <- hook world "stop" (agentStop "engineer" "e1" ["e1"])
                atWorktree world "/work"

                listed <- succeeded =<< state world ["tasks"]
                listed `shouldSatisfy` any (Text.isPrefixOf ("child " <> child <> " engineer stopped, no hand-back at "))
                listed `shouldContain` ["  RESUME " <> child <> " stopped, no hand-back: a fresh engineer from its notes /child"]

            it "records nothing in a child run at the stop of a worker its lead spawned" $ \world -> do
                _ <- engineerAtWork world
                _ <- succeeded =<< hook world "bind" (spawnResultBy "engineer" "e1" "implementer" "w1")
                before' <- loggedEventsIn world "/child"

                said <- hook world "stop" (agentStop "implementer" "w1" ["e1"])

                (said.code, said.out) `shouldBe` (0, [])
                loggedEventsIn world "/child" `shouldReturn` before'

            it "records nothing in a child run at the lead's stop for a worker there that runs no more" $ \world -> do
                _ <- engineerAtWork world
                _ <- succeeded =<< hook world "bind" (spawnResultBy "engineer" "e1" "implementer" "w1")
                before' <- loggedEventsIn world "/child"
                atWorktree world "/work"

                _ <- hook world "stop" (leadStop ["e1"])

                loggedEventsIn world "/child" `shouldReturn` before'

            it "records the agent its spawner's stop call names ended" $ \world -> do
                _ <- engineerAtWork world

                _ <- hook world "stop" (stopCall "e1")

                filter (== "agent_ended") <$> loggedEventsIn world "/child" `shouldReturn` ["agent_ended"]

            it "lists a child at work as before, with no resume step" $ \world -> do
                child <- engineerAtWork world
                atWorktree world "/work"

                listed <- succeeded =<< state world ["tasks"]

                listed `shouldSatisfy` any (Text.isPrefixOf ("child " <> child <> " engineer at "))
                listed `shouldSatisfy` not . any (Text.isInfixOf "RESUME")

            it "records nothing for a child run that handed back, by a question up or by its stop" $ \world -> do
                _ <- engineerAtWork world
                _ <- succeeded =<< state world ["ask", "--kind", "Design", "which", "store?"]
                asked <- loggedEventsIn world "/child"
                _ <- hook world "stop" (agentStop "engineer" "e1" [])
                afterAsked <- loggedEventsIn world "/child"
                _ <- succeeded =<< state world ["stop", "failed", "no", "access"]
                over <- loggedEventsIn world "/child"
                _ <- hook world "stop" (agentStop "engineer" "e1" [])

                afterAsked `shouldBe` asked
                loggedEventsIn world "/child" `shouldReturn` over

            it "records nothing for a plain worker's stop" $ \world -> do
                _ <- drive world (Record ["fuel.set", "balanced"] : init toImplement)
                _ <- hook world "bind" (spawnResult "implementer")
                before' <- logRows world

                said <- hook world "stop" (agentStop "implementer" "a1" [])

                (said.code, said.out) `shouldBe` (0, [])
                logRows world `shouldReturn` before'

            it "records the lead's child ended at the lead's stop once it runs no more" $ \world -> do
                _ <- engineerAtWork world
                atWorktree world "/work"

                _ <- hook world "stop" (leadStop ["e1"])
                running <- filter (== "agent_ended") <$> loggedEventsIn world "/child"
                stopped <- hook world "stop" (leadStop [])

                (running, stopped.code, stopped.out) `shouldBe` ([], 0, [])
                filter (== "agent_ended") <$> loggedEventsIn world "/child" `shouldReturn` ["agent_ended"]

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
                _ <- drive world [Record ["fuel.set", "balanced"]]
                before' <- logRows world

                _ <- hook world "handback" "not json"

                after <- logRows world
                after `shouldBe` before'

-- | Calls the architect's run denies: a commit, a push, a PR opened.
writing :: [Text]
writing = ["git commit -m x", "git push -u origin HEAD", "gh pr create --draft"]

-- | Calls the architect's run lets through: its ticket, by @gh issue@ and a heredoc.
issuing :: [Text]
issuing = ["gh issue create --repo o/r --title t --body x", "gh issue edit 1 --repo o/r --body-file - <<'EOF'\n# Design\nEOF"]

-- | Whether the route hook denied the call, naming the architect flow.
denies :: Ran -> Bool
denies said = any ("the architect flow changes no code" `Text.isInfixOf`) said.out

-- | The @context@ of the reply printed, if any.
contextOf :: Ran -> Maybe Text
contextOf said = case decodeStrictText (Text.concat said.out) of
    Just (Object reply) | Just (String context) <- KeyMap.lookup "context" reply -> Just context
    _ -> Nothing

-- | Session @s1@'s bindings, under the world's @HOME@.
bindings :: FilePath
bindings = "/home/.local/state/state/bindings/s1"

-- | At Balanced, the gather's research picked: a researcher's spawn is recorded here.
researching :: [Act]
researching = [Record ["fuel.set", "balanced"], Record ["gather.research"]]

{- | A 10x at its fan-out, and its engineer @e1@ on task t1, bound by its
init's hook to the child run in @/child@, where later calls run; the child's id.
-}
engineerAtWork :: IORef World -> IO Text
engineerAtWork world = do
    parent <- tenXAtFanOut world
    child <- childRun world parent "/child" "t1"
    _ <- succeeded =<< hook world "bind" (initRan "engineer" "e1" ("started " <> child <> "\nrun " <> child <> " /child " <> Text.pack childWorktree <> "\n"))
    pure child
