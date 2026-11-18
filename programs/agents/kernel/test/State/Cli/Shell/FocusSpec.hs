{- | @state focus@ and @state tasks@ over the doubles, the clock fixed: a
chief's request switch, its cards and the 5-minute resume advice.
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
                               , "  resume agent a7: paused under 5 minutes, its cache is warm (SendMessage)"
                               ]
                           ,
                               [ "notes /notes"
                               , "r2 in focus at fuel"
                               , "r1 paused 6m at architect/fuel: researching the store"
                               , "  fresh agent from card: paused 5 minutes or more, its cache is cold"
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
                           , "  resume agent a7: paused under 5 minutes, its cache is warm (SendMessage)"
                           ]
            after `shouldBe` before'

        it "opens a new request, then drops it untouched on the turn back: no card is left of it" $ \world -> do
            researching world
            _ <- succeeded =<< state world ["focus", "--summary", "researching the store"]
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

            (refused.code, refused.err) `shouldBe` (2, ["state focus: the turn away from r1 - it recorded work: its card says where it stands", "fix: state focus --summary <where it stands>"])

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

later :: IORef World -> NominalDiffTime -> IO ()
later world seconds = modifyIORef' world (\w -> w {clock = addUTCTime seconds w.clock})
