module State.StepsSpec (spec) where

import Data.Aeson (Value (..), decode, encode)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LBS
import Data.Either (fromLeft)
import Data.Maybe (fromMaybe)
import State.Steps (parseSteps)
import System.Environment (getEnv)
import Test.Hspec (Spec, describe, it, runIO, shouldBe)

spec :: Spec
spec = describe "State.Steps" $ do
    -- The build exports the flows' table as STATE_STEPS (kernel/default.nix).
    table <- runIO (LBS.readFile =<< getEnv "STATE_STEPS")
    let rows = fromMaybe (error "STATE_STEPS is not a JSON object") (decode table >>= asObject)
        reparse = problems . encode . Object
        rowNamed key = fromMaybe (error "no such row") (KeyMap.lookup key rows)

    it "steps_match" $
        problems table `shouldBe` []

    it "refuses a row whose cod is not its step's" $
        reparse (KeyMap.insert "plan" (setField "cod" "Diff" (rowNamed "plan")) rows)
            `shouldBe` ["plan: cod is Diff, the step's is Plan"]

    it "refuses a table missing a step's row" $
        reparse (KeyMap.delete "fix" rows) `shouldBe` ["fix: no row"]

    it "refuses an inline row with a lead" $
        reparse (KeyMap.insert "plan" (setField "lead" "Spawn one." (rowNamed "plan")) rows)
            `shouldBe` ["plan: an inline step has no lead"]

    it "refuses a role's row without a lead" $
        reparse (KeyMap.insert "fix" (dropField "lead" (rowNamed "fix")) rows)
            `shouldBe` ["fix: a step run by fixer needs a lead"]

    it "refuses a row for no step" $
        reparse (KeyMap.insert "deploy" (rowNamed "fix") rows)
            `shouldBe` ["deploy: no such step"]
  where
    -- 'Steps' has no Eq: what is checked is the list of problems.
    problems = fromLeft [] . parseSteps
    asObject = \case
        Object obj -> Just obj
        _ -> Nothing
    setField key value = \case
        Object obj -> Object (KeyMap.insert key (String value) obj)
        other -> other
    dropField key = \case
        Object obj -> Object (KeyMap.delete key obj)
        other -> other
