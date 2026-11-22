module Effects.FileSystemSpec (spec) where

import Control.Exception (try)
import Data.List (sort)
import Effectful (runEff)
import Effects.FileSystem (
    createDirectory,
    inDirectory,
    listDirectory,
    readBytes,
    readText,
    removeFile,
    runFileSystemIO,
    writeText,
    writeTextAtomic,
 )
import System.Directory qualified as Directory
import System.FilePath ((</>))
import System.IO.Error (isDoesNotExistError)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, around, describe, it, shouldBe, shouldReturn)

spec :: Spec
spec = describe "Effects.FileSystem" $ around (withSystemTempDirectory "state-fs") $ do
    it "writes a file's text and reads it back" $ \dir -> do
        let file = dir </> "pointer"

        text <-
            runEff . runFileSystemIO $ writeText file "/notes ünïcode\n" >> readText file

        text `shouldBe` Just "/notes ünïcode\n"

    it "reads no text of an absent file" $ \dir ->
        (runEff . runFileSystemIO $ readText (dir </> "absent")) `shouldReturn` Nothing

    it "throws on the bytes of an absent file" $ \dir -> do
        read' <- try (runEff . runFileSystemIO $ readBytes (dir </> "absent"))

        either isDoesNotExistError (const False) read' `shouldBe` True

    it "creates a directory and its missing parents" $ \dir -> do
        let deep = dir </> "a" </> "b"

        runEff . runFileSystemIO $
            createDirectory deep >> createDirectory deep >> writeText (deep </> "f") "x"

        (runEff . runFileSystemIO $ readText (deep </> "f")) `shouldReturn` Just "x"

    it "replaces a file's text whole, leaving no temp file beside it" $ \dir -> do
        let file = dir </> "binding"

        text <-
            runEff . runFileSystemIO $
                writeText file "old" >> writeTextAtomic file "run ünïcode\n" >> readText file

        text `shouldBe` Just "run ünïcode\n"
        Directory.listDirectory dir `shouldReturn` ["binding"]

    it "removes a file, and one already absent" $ \dir -> do
        let file = dir </> "stash"

        runEff . runFileSystemIO $
            writeText file "x" >> removeFile file >> removeFile file

        Directory.listDirectory dir `shouldReturn` []

    it "lists a directory's names, and none of an absent one" $ \dir -> do
        names <-
            runEff . runFileSystemIO $
                createDirectory (dir </> "s1")
                    >> writeText (dir </> "main") "x"
                    >> listDirectory dir
        absent <- runEff . runFileSystemIO $ listDirectory (dir </> "absent")

        (sort names, absent) `shouldBe` (["main", "s1"], [])

    it "resolves relative paths against the directory it runs in" $ \dir -> do
        runEff . runFileSystemIO $ createDirectory (dir </> "work")

        text <-
            runEff . runFileSystemIO . inDirectory (dir </> "work") $
                writeText "f" "x" >> readText (dir </> "work" </> "f")

        text `shouldBe` Just "x"
