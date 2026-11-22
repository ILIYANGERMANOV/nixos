module State.Cli.ShellSpec (spec) where

import Effects.Store (Durability (..))
import State.Cli.Shell (storeDurability)
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec = describe "State.Cli.Shell"
    $ it
        "keeps the store fully synced unless argv opens with --store-durability unsynced"
    $ do
        storeDurability ["next"] `shouldBe` (Full, ["next"])
        storeDurability ["next", "--store-durability", "unsynced"]
            `shouldBe` (Full, ["next", "--store-durability", "unsynced"])
        storeDurability ["--store-durability", "unsynced", "next"]
            `shouldBe` (Unsynced, ["next"])
