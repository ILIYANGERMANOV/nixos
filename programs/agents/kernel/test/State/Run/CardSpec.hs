module State.Run.CardSpec (spec) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Set qualified as Set
import State.Category.Fuel (Fuel (..))
import State.Run.Ask (
    Above (..),
    Kind (Design, Pick),
    Proposal (..),
    QId (..),
    Question (..),
 )
import State.Run.Card (Card (..), Standing (..), cards)
import State.Run.Event
import State.Run.EventGen (absolutePath, fuelSet, logOf, oneLine, run)
import State.Run.Fold (trace)
import State.Run.RunGen (chiefGraph)
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec = do
    describe "cards"
        $ it
            "gives the request in focus and each waiting one its node, its own decisions and open questions"
        $ do
            -- Each question's qid is its line's seq, as the shell writes it.
            let asked n kind =
                    Asking
                        (Question (QId run n) kind (oneLine "which store?"))
                        (StateName "fuel")
                        Itself
                logged =
                    logOf
                        ( Started
                            ( Start
                                ChiefFlow
                                "notes"
                                (ByUser OwnPr)
                                Set.empty
                                (absolutePath "/work")
                                Nothing
                            )
                            :| [ Asked (asked 1 Design)
                               , Forwarded (QId run 1) TheUser
                               , SpanStarted
                                    ( SpanStart
                                        (AgentRole "researcher")
                                        (Harness "claude-code")
                                        "research"
                                        Nothing
                                        Nothing
                                    )
                               , Suspended (TaskNo 1) (oneLine "asked which store")
                               , Asked (asked 5 Pick)
                               , RuledOn
                                    (QId run 5)
                                    (Proposal (oneLine "sqlite") (oneLine "one user") (oneLine "none") Nothing)
                               , fuelSet Balanced
                               ]
                        )
                suspendedAt = (logged NonEmpty.!! 4).ts
            fmap cards (trace chiefGraph logged)
                `shouldBe` Right
                    [ Card
                        (TaskNo 2)
                        InFocus
                        (StateName "route")
                        [(QId run 5, Pick, Chose "sqlite")]
                        []
                    , Card
                        (TaskNo 1)
                        (Paused suspendedAt (oneLine "asked which store"))
                        (StateName "fuel")
                        []
                        [Question (QId run 1) Design (oneLine "which store?")]
                    ]
