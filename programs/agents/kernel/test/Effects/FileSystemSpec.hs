module Effects.FileSystemSpec (spec) where

import Control.Exception (try)
import Effectful (runEff)
import Effects.FileSystem (createDirectory, inDirectory, makeAbsolute, readBytes, readText, runFileSystemIO, writeText)
import System.FilePath ((</>))
import System.IO.Error (isDoesNotExistError)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, around, describe, it, shouldBe, shouldReturn)

spec :: Spec
spec = describe "Effects.FileSystem" $ around (withSystemTempDirectory "state-fs") $ do
    it "writes a file's text and reads it back" $ \dir -> do
        let file = dir </> "pointer"

        text <- runEff . runFileSystemIO $ writeText file "/notes ünïcode\n" >> readText file

        text `shouldBe` Just "/notes ünïcode\n"

    it "reads no text of an absent file" $ \dir ->
        (runEff . runFileSystemIO $ readText (dir </> "absent")) `shouldReturn` Nothing

    it "throws on the bytes of an absent file" $ \dir -> do
        read' <- try (runEff . runFileSystemIO $ readBytes (dir </> "absent"))

        either isDoesNotExistError (const False) read' `shouldBe` True

    it "creates a directory and its missing parents" $ \dir -> do
        let deep = dir </> "a" </> "b"

        runEff . runFileSystemIO $ createDirectory deep >> createDirectory deep >> writeText (deep </> "f") "x"

        (runEff . runFileSystemIO $ readText (deep </> "f")) `shouldReturn` Just "x"

    it "resolves relative paths against the directory it runs in" $ \dir -> do
        runEff . runFileSystemIO $ createDirectory (dir </> "work")

        (absolute, text) <- runEff . runFileSystemIO . inDirectory (dir </> "work") $ (,) <$> makeAbsolute "f" <*> (writeText "f" "x" >> readText (dir </> "work" </> "f"))

        (absolute, text) `shouldBe` (dir </> "work" </> "f", Just "x")
