{- | @state focus@ and @state tasks@ over the doubles, the clock fixed: a
chief's request switch, its cards and the resume advice (5-minute cache, 15s buffer).
-}
module State.Cli.Shell.FocusSpec (spec) where

import Control.Monad ((<=<))
import Data.IORef (IORef, modifyIORef')
import Data.Text (Text)
import Data.Time (NominalDiffTime, addUTCTime)
import State.Cli.Shell.World
import Test.Hspec (Spec, before, describe, it, shouldBe)

spec :: Spec
spec = describe "a chief's request switch over the doubles" $ before newWorld $ do
    describe "state tasks" $
        it "prints a waiting request's card, advising its worker resumed at 4 minutes and a fresh agent from the card at 6" $ \world -> do
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
        it "turns back to a waiting request at its node, its card advising by the two logged times" $ \world -> do
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

        it "opens a new request, then drops it untouched on the turn back: no card is left of it" $ \world -> do
            researching world
            _ <- succeeded =<< state world ["focus", "--summary", "researching the store"]
            _ <- succeeded =<< state world ["focus", "r1"]

            tasks <- succeeded =<< state world ["tasks"]

            tasks `shouldBe` ["notes /notes", "r1 in focus at architect/fuel"]

        it "records a finished request done on a turn away, with no summary: no card is left of it, and it is not waiting" $ \world -> do
            finished world

            away <- succeeded =<< state world ["focus"]
            tasks <- succeeded =<< state world ["tasks"]
            refused <- state world ["focus", "r1"]

            (away, tasks, (refused.code, refused.err))
                `shouldBe` ( ["recorded 5 next.request -> fuel", "r2 in focus at fuel"]
                           , ["notes /notes", "r2 in focus at fuel"]
                           , (2, ["state focus: the focus on r1 - it is not a waiting request", "fix: state tasks"])
                           )

        it "drops a finished request on the turn back to a waiting one: only the waiting one is left" $ \world -> do
            researching world
            _ <- succeeded =<< state world ["focus", "--summary", "researching the store"]
            finishRequest world

            _ <- succeeded =<< state world ["focus", "r1"]
            tasks <- succeeded =<< state world ["tasks"]

            tasks `shouldBe` ["notes /notes", "r1 in focus at architect/fuel"]

        it "refuses a turn to a request that is not waiting, naming state tasks" $ \world -> do
            researching world

            refused <- state world ["focus", "r1", "--summary", "researching the store"]

            (refused.code, refused.err) `shouldBe` (2, ["state focus: the focus on r1 - it is not a waiting request", "fix: state tasks"])

        it "refuses a turn away from a request that recorded work without saying where it stands" $ \world -> do
            researching world

            refused <- state world ["focus"]

            (refused.code, refused.err) `shouldBe` (2, ["state focus: the turn away from r1 - it recorded work: it is suspended first", "fix: state focus [<request>] --summary <where it stands>"])

        it "refuses a turn away from a finished request at the Requests cap, naming extend, and state next asks to go on" $ \world -> do
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

        it "turns back to a waiting request at the Requests cap, as a turn back opens no new request" $ \world -> do
            _ <- startedIn world ["--flow", "chief"]
            mapM_ (succeeded <=< state world) ([["record", "fuel.set", "low"], ["record", "route.architect"], ["focus", "--summary", "researching the store"]] :: [[Text]])
            spendRequests world

            back <- state world ["focus", "r1"]
            tasks <- succeeded =<< state world ["tasks"]

            (back.code, tasks) `shouldBe` (0, ["notes /notes", "r1 in focus at architect/fuel"])

        it "refuses a request switch in a run of a flow that does not switch requests" $ \world -> do
            _ <- startedRun world

            refused <- state world ["focus"]

            (refused.code, refused.err) `shouldBe` (2, ["state focus: the request switch - only a chief run going on switches requests", "fix: state next"])

-- | A chief run in its architect request, a researcher @a7@ at work.
researching :: IORef World -> IO ()
researching world = do
    _ <- startedIn world ["--flow", "chief"]
    mapM_ (succeeded <=< state world) ([["record", "fuel.set", "balanced"], ["record", "route.architect"]] :: [[Text]])
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

-- | The request in focus and 50 more run to their end at Low Fuel: the Requests cap is spent.
spendRequests :: IORef World -> IO ()
spendRequests world = mapM_ (succeeded <=< state world) (concat (replicate 50 (request <> [["record", "next.request"]])) <> request)
  where
    request = [["record", "fuel.set", "low"], ["record", "route.other"], ["record", "direct.done", "renamed a file"]] :: [[Text]]

-- | The request in focus runs its route to its end, at @next@.
finishRequest :: IORef World -> IO ()
finishRequest world = mapM_ (succeeded <=< state world) ([["record", "fuel.set", "balanced"], ["record", "route.other"], ["record", "direct.done", "renamed a file"]] :: [[Text]])

later :: IORef World -> NominalDiffTime -> IO ()
later world seconds = modifyIORef' world (\w -> w {clock = addUTCTime seconds w.clock})
