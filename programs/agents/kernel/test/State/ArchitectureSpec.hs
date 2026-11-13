-- | Checks on how the kernel's modules import each other.
module State.ArchitectureSpec (spec) where

import Data.Char (toLower)
import Data.List (isInfixOf, isSuffixOf, stripPrefix)
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

    -- Law Principal-blind: the kernel has no word for who started a run. The
    -- test fixtures may still spell the Python log's key.
    it "no_delegated_word" $ do
        files <- concat <$> traverse sourceFiles ["src", "app"]
        sources <- traverse (\file -> (file,) <$> readFile file) files
        [file | (file, source) <- sources, "delegated" `isInfixOf` map toLower source] `shouldBe` []

-- | Every Haskell file under a directory of the package.
sourceFiles :: FilePath -> IO [FilePath]
sourceFiles dir = do
    entries <- map ((dir <> "/") <>) <$> listDirectory dir
    concat <$> traverse below entries
  where
    below entry =
        doesDirectoryExist entry >>= \case
            True -> sourceFiles entry
            False -> pure [entry | ".hs" `isSuffixOf` entry]

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
