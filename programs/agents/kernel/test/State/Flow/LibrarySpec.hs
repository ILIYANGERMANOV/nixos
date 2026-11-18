module State.Flow.LibrarySpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import State.Category.Flow (Branch (..), Branches (..), Flow (..), Shape (..))
import State.Category.Fuel (Fuel (..), PerFuel (..), SkipWhen (..), always, atFuel)
import State.Category.Graph (Cap (..), OpenGraph (..), graph)
import State.Category.Meter (AtCap (..), Limit (..), someMeterName)
import State.Category.Step (eventText)
import State.Category.Ty (TyOf (..))
import State.Flow.Engineer (engineer)
import State.Flow.Library (ChoiceS, SkippableS, agree, build, choice, describe, fixReReview, gather, propose, review, ship, skippableBlock)
import State.Step.Catalog (flowOutcomes, outcomeEvent, termSkips, termSteps)
import Test.Hspec (Spec, it, shouldBe)
import Test.Hspec qualified as Hspec

spec :: Spec
spec = Hspec.describe "State.Flow.Library" $ do
    it "builds every flow" $
        [ name
        | (name, Left _) <-
            [ ("agree", graph agree)
            , ("gather", graph gather)
            , ("propose", graph propose)
            , ("build", graph build)
            , ("fixReReview", graph fixReReview)
            , ("review", graph review)
            , ("describe", graph describe)
            , ("ship", graph ship)
            ]
        ]
            `shouldBe` ([] :: [String])

    {- Each cap keeps today's rounds as spends: a round after the first is
    an adjusted plan, a fix of a red CI, a re-review.
    -}
    it "caps each loop's metered step, and says what a spend past it does" $
        Map.fromList . map (\cap -> (someMeterName cap.meter, (cap.limit, cap.atCap))) . Map.elems . (.caps) <$> graph engineer
            `shouldBe` Right
                ( Map.fromList
                    [ ("Researchers", (PerFuel (UpTo 1) (UpTo 5) PerGroup, Extend))
                    , ("Interview questions", (UpTo <$> PerFuel 15 30 50, Extend))
                    , ("Plan rounds", (always (UpTo 3), Stop))
                    , ("Re-reviews", (UpTo <$> PerFuel 1 3 5, Refuse))
                    , ("CI fixes", (always (UpTo 5), Stop))
                    ]
                )

    -- Research is no skip: the gather's agent chooses it, or enough.
    it "leaves the plan's simplify and the refactor skippable at Low only" $
        [(level, skippableAt level) | level <- [minBound .. maxBound]]
            `shouldBe` [(Low, Set.fromList ["refactor", "simplify_plan"]), (Balanced, Set.empty), (Max, Set.empty)]

    -- No layer lists a flow's picks and skips: the flow's term names each way on.
    it "names each label of a choice and both ways of a skippable block as the events a run records" $
        map (eventText . outcomeEvent) (concatMap flowOutcomes (termSteps sized))
            `shouldBe` ["size.small", "size.big", "skip_tidy.skip", "skip_tidy.run"]
  where
    sized :: Flow (ChoiceS 'Ctx '[ '("small", 'Ctx), '("big", 'Ctx)] '[IdS, IdS] :>> SkippableS 'Ctx IdS) 'Ctx 'Nothing 'Ctx
    sized = choice "size" (#small :-> Id :& #big :-> Id :& End) :> skippableBlock "tidy" (always Skippable) Id
    skippableAt level = Set.fromList [name | (name, when) <- termSkips engineer, atFuel level when == Skippable]
