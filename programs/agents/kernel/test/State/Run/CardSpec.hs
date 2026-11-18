module State.Run.CardSpec (spec) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Set qualified as Set
import Data.Time (NominalDiffTime, UTCTime (..), addDays, addUTCTime, fromGregorian)
import Hedgehog (Gen, forAll, (===))
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import State.Run.Ask (Above (..), Kind (Design), Principal (..), Proposal (..), QId (..), Question (..), Reply (..))
import State.Run.Card (Card (..), ResumeAdvice (..), Standing (..), cards, resumeAdvice)
import State.Run.Event
import State.Run.EventGen (fuelSet, logOf, oneLine, run)
import State.Run.Fold (trace)
import State.Run.RunGen (chiefGraph)
import State.Step.Fuel (Fuel (..))
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.Hedgehog (hedgehog)

spec :: Spec
spec = do
    describe "resumeAdvice" $ do
        it "resumes_the_worker_of_a_request_paused_under_five_minutes" . hedgehog $ do
            pausedAt <- forAll genTime
            paused <- forAll (genSeconds 0 299.999)
            resumeAdvice pausedAt (addUTCTime paused pausedAt) agent === ResumeAgent agent

        it "starts_a_fresh_agent_from_the_card_of_a_request_paused_five_minutes_or_more" . hedgehog $ do
            pausedAt <- forAll genTime
            paused <- forAll (genSeconds 300 86400)
            resumeAdvice pausedAt (addUTCTime paused pausedAt) agent === FreshFromCard

    describe "cards" $
        it "gives the request in focus and each waiting one its node, its own decisions and open questions, and its last worker" $ do
            let asked n = Asking (Question (QId run n) Design (oneLine "which store?")) (StateName "fuel") Itself
                logged =
                    logOf
                        ( Started (Start ChiefFlow "notes" (ByUser OwnPr) Set.empty)
                            :| [ Asked (asked 1)
                               , Forwarded (QId run 1) TheUser
                               , WorkerSpawned (AgentRole "researcher") agent
                               , Suspended (TaskNo 1) (oneLine "asked which store")
                               , Asked (asked 2)
                               , RuledOn (QId run 2) (Proposal (oneLine "sqlite") (oneLine "one user") (oneLine "none") Nothing)
                               , fuelSet Balanced
                               ]
                        )
                suspendedAt = (logged NonEmpty.!! 4).ts
            fmap cards (trace chiefGraph logged)
                `shouldBe` Right
                    [ Card (TaskNo 2) InFocus (StateName "route") [(QId run 2, Chose "sqlite")] [] Nothing
                    , Card (TaskNo 1) (Paused suspendedAt (oneLine "asked which store")) (StateName "fuel") [] [Question (QId run 1) Design (oneLine "which store?")] (Just agent)
                    ]
  where
    agent = AgentId "a7"

genTime :: Gen UTCTime
genTime = (\day -> UTCTime (addDays day (fromGregorian 2026 1 1)) 0) <$> Gen.integral (Range.linear 0 3650)

-- | Seconds between these bounds, to the millisecond.
genSeconds :: NominalDiffTime -> NominalDiffTime -> Gen NominalDiffTime
genSeconds low high = (/ 1000) . fromInteger <$> Gen.integral (Range.linear (round (low * 1000)) (round (high * 1000)))
