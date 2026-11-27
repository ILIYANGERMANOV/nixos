{- | @state focus@ and @state tasks@ over the doubles, the clock fixed: a
chief's request switch, its cards and the resume advice (5-minute cache, 15s buffer).
-}
module State.Cli.Shell.FocusSpec (spec) where

import Control.Monad ((<=<))
import Data.Entity.Event (EventRow (..))
import Data.IORef (IORef, modifyIORef')
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)
import Data.Time (NominalDiffTime, addUTCTime)
import State.Cli.Shell.World
import State.Run.RunGen (breakdownJson, plainTask)
import System.FilePath ((</>))
import Test.Hspec (Spec, before, describe, it, shouldBe)

spec :: Spec
spec = describe "a chief's request switch over the doubles" $ before newWorld $ do
    describe "state tasks"
        $ it
            "prints a waiting request's card, advising its worker resumed at 4 minutes and a fresh agent from the card at 6"
        $ \world -> do
            researching world

            _ <- succeeded =<< state world ["focus", "--summary", "researching the store"]
            later world 240
            atFour <- succeeded =<< state world ["tasks"]
            later world 120
            atSix <- succeeded =<< state world ["tasks"]

            (atFour, atSix)
                `shouldBe` (
                               [ "notes /notes"
                               , "r2 in focus at fuel"
                               , "r1 paused 4m at architect/fuel: researching the store"
                               , "  resume agent a7: paused under 4m45s, its cache is warm (SendMessage)"
                               ]
                           ,
                               [ "notes /notes"
                               , "r2 in focus at fuel"
                               , "r1 paused 6m at architect/fuel: researching the store"
                               , "  fresh agent from card: paused 4m45s or more, its cache is cold"
                               ]
                           )

    describe "state focus" $ do
        it
            "turns back to a waiting request at its node, its card advising by the two logged times"
            $ \world -> do
                researching world
                before' <- succeeded =<< state world ["show"]
                _ <- succeeded =<< state world ["focus", "--summary", "researching the store"]
                later world 240

                back <- succeeded =<< state world ["focus", "r1"]
                after <- succeeded =<< state world ["show"]

                back
                    `shouldBe` [ "recorded 6 focused -> architect/fuel"
                               , "r1 paused 4m at architect/fuel: researching the store"
                               , "  resume agent a7: paused under 4m45s, its cache is warm (SendMessage)"
                               ]
                after `shouldBe` before'

        it
            "opens a new request, then drops it untouched on the turn back: no card is left of it"
            $ \world -> do
                researching world
                _ <- succeeded =<< state world ["focus", "--summary", "researching the store"]
                _ <- succeeded =<< state world ["focus", "r1"]

                tasks <- succeeded =<< state world ["tasks"]

                tasks `shouldBe` ["notes /notes", "r1 in focus at architect/fuel"]

        it
            "records a finished request done on a turn away, with no summary: no card is left of it, and it is not waiting"
            $ \world -> do
                finished world

                away <- succeeded =<< state world ["focus"]
                tasks <- succeeded =<< state world ["tasks"]
                refused <- state world ["focus", "r1"]

                (away, tasks, (refused.code, refused.err))
                    `shouldBe` ( ["recorded 5 next.request -> fuel", "r2 in focus at fuel"]
                               , ["notes /notes", "r2 in focus at fuel"]
                               ,
                                   ( 2
                                   ,
                                       [ "state focus: the focus on r1 - it is not a waiting request"
                                       , "fix: state tasks"
                                       ]
                                   )
                               )

        it
            "drops a finished request on the turn back to a waiting one: only the waiting one is left"
            $ \world -> do
                researching world
                _ <- succeeded =<< state world ["focus", "--summary", "researching the store"]
                finishRequest world

                _ <- succeeded =<< state world ["focus", "r1"]
                tasks <- succeeded =<< state world ["tasks"]

                tasks `shouldBe` ["notes /notes", "r1 in focus at architect/fuel"]

        it "refuses a turn to a request that is not waiting, naming state tasks" $ \world -> do
            researching world

            refused <- state world ["focus", "r1", "--summary", "researching the store"]

            (refused.code, refused.err)
                `shouldBe` ( 2
                           ,
                               [ "state focus: the focus on r1 - it is not a waiting request"
                               , "fix: state tasks"
                               ]
                           )

        it
            "refuses a turn away from a request that recorded work without saying where it stands"
            $ \world -> do
                researching world

                refused <- state world ["focus"]

                (refused.code, refused.err)
                    `shouldBe` ( 2
                               ,
                                   [ "state focus: the turn away from r1 - it recorded work: it is suspended first"
                                   , "fix: state focus [<request>] --summary <where it stands>"
                                   ]
                               )

        it
            "refuses a turn away from a finished request at the Requests cap, naming extend, and state next asks to go on"
            $ \world -> do
                atCap world

                away <- state world ["focus"]
                next <- state world ["next"]

                ((away.code, away.err), take 1 next.out)
                    `shouldBe` (
                                   ( 2
                                   ,
                                       [ "state focus: the spend at next - Requests allows 50 at this Fuel, all spent"
                                       , "fix: state record extend <why> | state record next.done"
                                       ]
                                   )
                               , ["ASK Stuck Requests: 50 of 50 used, none left: go on?"]
                               )

        it
            "turns back to a waiting request at the Requests cap, as a turn back opens no new request"
            $ \world -> do
                _ <- startedIn world ["--flow", "chief"]
                mapM_
                    (succeeded <=< state world)
                    ( [ ["record", "fuel.set", "low"]
                      , ["record", "route.architect"]
                      , ["focus", "--summary", "researching the store"]
                      ] ::
                        [[Text]]
                    )
                spendRequests world

                back <- state world ["focus", "r1"]
                tasks <- succeeded =<< state world ["tasks"]

                (back.code, tasks)
                    `shouldBe` (0, ["notes /notes", "r1 in focus at architect/fuel"])

        it "refuses a request switch in a run of a flow that does not switch requests" $ \world -> do
            _ <- startedRun world

            refused <- state world ["focus"]

            (refused.code, refused.err)
                `shouldBe` ( 2
                           ,
                               [ "state focus: the request switch - only a chief run going on switches requests"
                               , "fix: state next"
                               ]
                           )

    describe "a waiting 10x request's task"
        $ it
            "takes a child of the task and the task's merge while another request has focus"
        $ \world -> do
            chief <- startedIn world ["--flow", "chief"]
            putFile world (notes </> "tasks.json") (breakdownJson [plainTask "t1" []])
            mapM_
                (succeeded <=< state world)
                ( [ ["record", "fuel.set", "balanced"]
                  , ["record", "route.10x"]
                  , ["override", "10x/breakdown", "the", "plan", "is", "agreed"]
                  , ["record", "breakdown.done", "--tasks", Text.pack (notes </> "tasks.json")]
                  , ["focus", "--summary", "engineers at work"]
                  ] ::
                    [[Text]]
                )

            atWorktree world childWorktree
            child <-
                state world ["init", "--notes", "/child", "--parent", chief, "--task", "t1"]
            atWorktree world "/work"
            merged <-
                state world ["record", "task", "t1", "merged", "https://github.com/o/r/pull/1"]
            tasks <- succeeded =<< state world ["tasks"]

            (child.code, child.err, merged.code, merged.err, take 2 tasks)
                `shouldBe` (0, [], 0, [], ["notes /notes", "r2 in focus at fuel"])

    describe "the chief's end" $ do
        it
            "ends with a request left suspended: suspend r1, run r2, resume r1, suspend it again, run r3 and end"
            $ \world -> do
                researching world
                _ <- succeeded =<< state world ["focus", "--summary", "researching the store"]
                finishRequest world
                _ <- succeeded =<< state world ["focus", "r1"]
                _ <- succeeded =<< state world ["focus", "--summary", "still researching"]
                finishRequest world

                atNext <- succeeded =<< state world ["next"]
                ended <- succeeded =<< state world ["record", "next.done"]
                next <- succeeded =<< state world ["next"]
                tasks <- succeeded =<< state world ["tasks"]

                ( filter ("r1 suspended" `Text.isInfixOf`) atNext
                    , recorded ended
                    , take 2 next
                    , filter ("r1 " `Text.isPrefixOf`) tasks
                    )
                    `shouldBe` (
                                   [ "  r1 suspended at architect/fuel: still researching - resume: state focus r1; next.done ends the run leaving it suspended"
                                   ]
                               , ["next.done -> out"]
                               , ["DONE", "  at the end: the flow is done"]
                               , ["r1 paused 0m at architect/fuel: still researching"]
                               )

    describe "a request handed on whole" $ do
        it
            "at the fork, says to spawn the child with its brief and record nothing, and so does a refused record"
            $ \world -> do
                _ <- delegating world

                next <- succeeded =<< state world ["next"]
                refusal <- state world ["record", "spawn_delegates.spawned"]

                ( take 1 next
                    , any
                        ( "record nothing - the child's state init --parent moves this run on"
                            `Text.isInfixOf`
                        )
                        next
                    , refusal.code
                    , drop 1 refusal.err
                    )
                    `shouldBe` (["RUN state brief engineer"], True, 2, ["fix: state brief engineer"])

        it
            "briefs an engineer child to record its Fuel line at fuel, and a 10x child that it runs at Balanced"
            $ \world -> do
                _ <- delegating world

                engineer <- succeeded =<< state world ["brief", "engineer"]
                tenX <- succeeded =<< state world ["brief", "10x"]

                (take 1 (drop 3 engineer), take 1 (drop 3 tenX))
                    `shouldBe` (
                                   [ "Your run starts at fuel: record the Fuel line there, state record fuel.set <level>."
                                   ]
                               , ["Your run starts past fuel, at Balanced: record no fuel.set."]
                               )

        it
            "moves the chief on to its next request at the child's init, listing the child with its last event"
            $ \world -> do
                chief <- delegating world
                later world 120
                child <- untaskedChild world chief
                later world 60
                atWorktree world "/work"

                shown <- succeeded =<< state world ["show"]
                tasks <- succeeded =<< state world ["tasks"]

                filter ("step:" `Text.isPrefixOf`) shown `shouldBe` ["step: next"]
                tasks
                    `shouldBe` [ "notes /notes"
                               , "r1 in focus at next"
                               , "child " <> child <> " engineer at fuel, last event 1m ago"
                               ]

        it "holds the chief's end until the child finishes" $ \world -> do
            chief <- delegating world
            child <- untaskedChild world chief
            atWorktree world "/work"

            waiting <- succeeded =<< state world ["record", "next.done"]
            _ <-
                succeeded
                    =<< stateIn
                        world
                        ("READY https://github.com/o/r/pull/1\nRun: " <> encodeUtf8 child)
                        ["handback", "engineer", "--child", child]
            next <- succeeded =<< state world ["next"]

            (recorded waiting, take 1 next)
                `shouldBe` (["next.done -> delegates"], ["DONE"])

        it "holds the chief's end until the child's agent stops with no hand-back" $ \world -> do
            chief <- delegating world
            child <- untaskedChild world chief
            _ <-
                succeeded
                    =<< hook
                        world
                        "bind"
                        ( initRan
                            "engineer"
                            "e1"
                            ( "started "
                                <> child
                                <> "\nrun "
                                <> child
                                <> " /child "
                                <> Text.pack childWorktree
                                <> "\n"
                            )
                        )
            atWorktree world "/work"
            _ <- succeeded =<< state world ["record", "next.done"]
            held <- succeeded =<< state world ["show"]

            _ <- hook world "stop" (agentStop "engineer" "e1" ["e1"])
            next <- succeeded =<< state world ["next"]

            (filter ("step:" `Text.isPrefixOf`) held, take 1 next)
                `shouldBe` (["step: delegates"], ["DONE"])

        it "starts the child past its plan's confirm, as the chief decided it" $ \world -> do
            chief <- delegating world
            _ <- untaskedChild world chief
            _ <- succeeded =<< state world ["record", "fuel.set", "balanced"]
            _ <- succeeded =<< state world ["record", "gather.enough"]
            _ <- succeeded =<< state world ["record", "gather/notes.done"]
            putFile world "/child/plan.md" "the plan"
            planned <- succeeded =<< state world ["record", "plan.done", "/child/plan.md"]
            advised <- succeeded =<< state world ["next"]

            recorded (planned <> advised)
                `shouldBe` [ "artifact -> plan"
                           , "plan.done -> skip_refine"
                           , "skip_refine.skip -> present"
                           , "present.done -> confirm"
                           , "confirm.confirmed -> draft"
                           ]

        it
            "starts a child at any later state of the chief as a direct child, not handed the request"
            $ \world -> do
                chief <- delegating world
                _ <- untaskedChild world chief
                handed <- succeeded =<< state world ["show"]
                atWorktree world "/work"
                _ <- succeeded =<< state world ["record", "next.request"]

                atWorktree world "/other-work"
                later' <- startedIn world ["--notes", "/other", "--parent", chief]
                shown <- succeeded =<< state world ["show"]
                atWorktree world "/work"
                tasks <- succeeded =<< state world ["tasks"]

                ( untasked handed
                    , untasked shown
                    , filter (("child " <> later') `Text.isPrefixOf`) tasks
                    )
                    `shouldBe` ( ["untasked: the parent handed on its request whole"]
                               , []
                               , ["child " <> later' <> " engineer at fuel, last event 0m ago"]
                               )
  where
    untasked = filter ("untasked" `Text.isPrefixOf`)

-- | A chief run in its architect request, a researcher @a7@ at work.
researching :: IORef World -> IO ()
researching world = do
    _ <- startedIn world ["--flow", "chief"]
    mapM_
        (succeeded <=< state world)
        ([["record", "fuel.set", "balanced"], ["record", "route.architect"]] :: [[Text]])
    _ <- hook world "bind" (spawnResultOf "researcher" "a7")
    pure ()

-- | A chief run whose first request ran to its end, at @next@.
finished :: IORef World -> IO ()
finished world = do
    _ <- startedIn world ["--flow", "chief"]
    finishRequest world

{- | A chief run at Low Fuel whose 51st request ran to its end: the 50
@next.request@ the Requests cap allows at Low are spent.
-}
atCap :: IORef World -> IO ()
atCap world = startedIn world ["--flow", "chief"] >> spendRequests world

{- | The request in focus and 50 more run to their end at Low Fuel: the Requests cap is spent.
The first runs through the CLI and the store holds its rows 49 times more, as
each call replays the whole log: 200 calls cost seconds.
-}
spendRequests :: IORef World -> IO ()
spendRequests world = do
    before' <- length <$> logRows world
    mapM_ (succeeded <=< state world) (request <> [["record", "next.request"]])
    spent <- drop before' <$> logRows world
    editLog
        world
        (<> concatMap (\k -> map (renumbered (k * length spent)) spent) [1 .. 49])
    mapM_ (succeeded <=< state world) request
  where
    request =
        [ ["record", "fuel.set", "low"]
        , ["record", "route.other"]
        , ["record", "direct.done", "renamed a file"]
        ] ::
            [[Text]]

-- | A logged row moved on by @n@ seqs.
renumbered :: Int -> EventRow -> EventRow
renumbered n row = row {seq = row.seq + fromIntegral n}

-- | The request in focus runs its route to its end, at @next@.
finishRequest :: IORef World -> IO ()
finishRequest world =
    mapM_
        (succeeded <=< state world)
        ( [ ["record", "fuel.set", "balanced"]
          , ["record", "route.other"]
          , ["record", "direct.done", "renamed a file"]
          ] ::
            [[Text]]
        )

later :: IORef World -> NominalDiffTime -> IO ()
later world seconds = modifyIORef' world (\w -> w {clock = addUTCTime seconds w.clock})
