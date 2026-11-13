-- | Checks on how the kernel's modules import each other, and the words its files use.
module State.ArchitectureSpec (spec) where

import Data.ByteString.Char8 qualified as ByteString
import Data.Char (toLower)
import Data.List (stripPrefix)
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import System.Directory (doesDirectoryExist, listDirectory)
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec = describe "kernel architecture" $ do
    it "keeps Principal and Op out of every flow module's imports (law Principal-blind)" $ do
        reached <- traverse (\name -> (name,) <$> closure name) flowModules
        [(name, Set.toList (Set.intersection modules environment)) | (name, modules) <- reached, not (Set.disjoint modules environment)]
            `shouldBe` []

    -- Law Principal-blind: the kernel has no word for who started a run, in
    -- any file the package builds from, tests and golden files too. The word
    -- is spelled in two halves so this file does not hold it either.
    it "names no principal mode in any of its files" $ do
        files <- (["state.cabal"] <>) . concat <$> traverse packageFiles ["src", "app", "test"]
        sources <- traverse (\file -> (file,) <$> ByteString.readFile file) files
        [file | (file, source) <- sources, ("dele" <> "gated") `ByteString.isInfixOf` ByteString.map toLower source] `shouldBe` []

-- | Every file under a directory of the package.
packageFiles :: FilePath -> IO [FilePath]
packageFiles dir = do
    entries <- map ((dir <> "/") <>) <$> listDirectory dir
    concat <$> traverse below entries
  where
    below entry =
        doesDirectoryExist entry >>= \case
            True -> packageFiles entry
            False -> pure [entry]

-- | The modules a flow is built from; none may know who runs it.
flowModules :: [String]
flowModules =
    [ "State.Cap"
    , "State.Flow"
    , "State.Flows.Blocks"
    , "State.Flows.Engineer"
    , "State.Flows.TenX"
    , "State.Graph"
    , "State.Mode"
    , "State.Path"
    ]

-- | The modules that define or re-export 'State.Ask.Principal' and 'State.Ask.Op'.
environment :: Set String
environment = Set.fromList ["State.Ask", "State.Event"]

-- | A module and every kernel module it imports, directly or not.
closure :: String -> IO (Set String)
closure = go Set.empty . pure
  where
    go seen = \case
        [] -> pure seen
        name : rest
            | Set.member name seen -> go seen rest
            | otherwise -> do
                imported <- kernelImports name
                go (Set.insert name seen) (imported <> rest)

-- | The kernel modules a module's source imports; the suite runs from the package root.
kernelImports :: String -> IO [String]
kernelImports name = mapMaybe imported . lines <$> readFile ("src/" <> map slash name <> ".hs")
  where
    slash = \case
        '.' -> '/'
        c -> c
    imported line = case words <$> stripPrefix "import " line of
        Just ("qualified" : target : _) -> kernel target
        Just (target : _) -> kernel target
        _ -> Nothing
    kernel target = target <$ stripPrefix "State." target
