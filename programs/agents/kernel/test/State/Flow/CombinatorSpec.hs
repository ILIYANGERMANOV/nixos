module State.Flow.CombinatorSpec (spec) where

import State.Category.Flow (Branch (..), Branches (..), Flow (..), Shape (..))
import State.Category.Fuel (SkipWhen (..), always)
import State.Category.Step (eventText)
import State.Category.Ty (TyOf (..))
import State.Flow.Combinator (ChoiceS, SkippableS, choice, skippableBlock)
import State.Step.Catalog (flowOutcomes, outcomeEvent, termSteps)
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec = describe "State.Flow.Combinator" $ do
    -- No layer lists a flow's picks and skips: the flow's term names each way on.
    it
        "names each label of a choice and both ways of a skippable block as the events a run records"
        $ map (eventText . outcomeEvent) (concatMap flowOutcomes (termSteps sized))
            `shouldBe` ["size.small", "size.big", "skip_tidy.skip", "skip_tidy.run"]
  where
    sized ::
        Flow
            ( ChoiceS 'Ctx '[ '("small", 'Ctx), '("big", 'Ctx)] '[IdS, IdS]
                :>> SkippableS 'Ctx IdS
            )
            'Ctx
            'Nothing
            'Ctx
    sized =
        choice "size" (#small :-> Id :& #big :-> Id :& End)
            :> skippableBlock "tidy" (always Skippable) Id
