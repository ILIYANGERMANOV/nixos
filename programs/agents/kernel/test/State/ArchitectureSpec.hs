-- | Checks on how the kernel's modules import each other, and the words its files use.
module State.ArchitectureSpec (spec) where

import Control.Applicative ((<|>))
import Data.ByteString.Char8 qualified as ByteString
import Data.Char (toLower)
import Data.List (isPrefixOf, isSuffixOf, stripPrefix)
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import System.Directory (doesDirectoryExist, listDirectory)
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec = describe "kernel architecture" $ do
    it
        "keeps Principal and Op out of every flow module's imports (law Principal-blind)"
        $ do
            reached <- traverse (\name -> (name,) <$> closure name) flowModules
            [ (name, Set.toList (Set.intersection modules environment))
              | (name, modules) <- reached
              , not (Set.disjoint modules environment)
              ]
                `shouldBe` []

    -- The category and its steps never reach the flows, the run or the
    -- command line, nor the run its protocol: a module imports its own layer
    -- or one below.
    it "keeps every layer's imports at its own layer or below" $ do
        names <- mapMaybe moduleOf <$> packageFiles "src"
        reached <- traverse (\name -> (name,) . Set.toList <$> closure name) names
        [ (name, upward)
          | (name, modules) <- reached
          , let upward = [m | m <- modules, any (`isPrefixOf` m) (higher name)]
          , not (null upward)
          ]
            `shouldBe` []

    -- Law Principal-blind: the kernel has no word for who started a run, in
    -- any file the package builds from, tests and golden files too. The word
    -- is spelled in two halves so this file does not hold it either.
    it "names no principal mode in any of its files" $ do
        files <-
            (["state.cabal"] <>) . concat <$> traverse packageFiles ["src", "app", "test"]
        sources <- traverse (\file -> (file,) <$> ByteString.readFile file) files
        [ file
          | (file, source) <- sources
          , ("dele" <> "gated") `ByteString.isInfixOf` ByteString.map toLower source
          ]
            `shouldBe` []

    -- Read, decide in pure code, write: only the effects and "State.Cli.Shell" do
    -- IO or name an effect; the two mains, under @app@, only interpret.
    it "keeps IO and effects out of every module but the effects' and the shell's" $ do
        decisions <-
            filter (\name -> not (name == shell || isEffects name)) . mapMaybe moduleOf
                <$> packageFiles "src"
        reached <- traverse (\name -> (name,) . Set.toList <$> closure name) decisions
        effects <-
            traverse
                ( \(name, modules) -> (name,) . concatMap (filter isEffect) <$> traverse imports modules
                )
                reached
        [found | found@(_, _ : _) <- effects] `shouldBe` []

    -- The store's layers (#552): Domain (@State.*@) < Data (pure rows and
    -- their mapping) < @Effects.Store.*@ (IO, SQL only). The store speaks rows:
    -- it reaches no domain module and no Domain<->row mapping, declares no
    -- row type, and only it names SQLite.
    it "lists every Data module the kernel has, so the rules below see each" $ do
        found <-
            filter ("Data." `isPrefixOf`) . mapMaybe moduleOf <$> packageFiles "src"
        Set.fromList found `shouldBe` Set.fromList kernelData

    it "keeps every Data module out of the domain's imports" $ do
        domain <-
            filter ("State." `isPrefixOf`) . mapMaybe moduleOf <$> packageFiles "src"
        found <-
            traverse (\name -> (name,) . filter (`elem` kernelData) <$> imports name) domain
        [bad | bad@(_, _ : _) <- found] `shouldBe` []

    it "keeps the domain and the payload mapping out of the store's reach" $ do
        store <- filter isStore . mapMaybe moduleOf <$> packageFiles "src"
        reached <- traverse (\name -> (name,) . Set.toList <$> closure name) store
        [ (name, bad)
          | (name, modules) <- reached
          , let bad =
                    filter (\m -> "State." `isPrefixOf` m || "Data.Payload." `isPrefixOf` m) modules
          , not (null bad)
          ]
            `shouldBe` []

    it "declares no row type in the store" $ do
        store <- filter isStore . mapMaybe moduleOf <$> packageFiles "src"
        sources <-
            traverse (\name -> (name,) . lines <$> readFile (sourceOf name)) store
        [ (name, declared)
          | (name, source) <- sources
          , declared <- source
          , Just (row : _) <-
                [words <$> (stripPrefix "data " declared <|> stripPrefix "newtype " declared)]
          , "Row" `isSuffixOf` row
          ]
            `shouldBe` []

    it "names SQLite in the store's modules only" $ do
        others <- filter (not . isStore) . mapMaybe moduleOf <$> packageFiles "src"
        found <-
            traverse
                (\name -> (name,) . filter ("Database." `isPrefixOf`) <$> imports name)
                others
        [bad | bad@(_, _ : _) <- found] `shouldBe` []

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
    [ "State.Category.Flow"
    , "State.Category.Fuel"
    , "State.Category.Graph"
    , "State.Category.Path"
    , "State.Category.Step"
    , "State.Category.Ty"
    , "State.Flow.Block"
    , "State.Flow.Combinator"
    , "State.Flow.Role.Engineer"
    , "State.Flow.Role.TenX"
    ]

{- | The kernel's layers, lowest first, each a set of module prefixes: the
category and its steps; the flows built from them, the roles that lead them
and the step table; the run's log and fold; the protocol a run speaks to its
agents; and the command line.
-}
layers :: [[String]]
layers =
    [ ["State.Category.", "State.Step."]
    , ["State.Flow.", "State.Role", "State.Table"]
    , ["State.Run."]
    , kernelData
    , ["State.Protocol."]
    , ["State.Cli."]
    ]

-- | The prefixes of the layers above a module's own; none for a module in no layer.
higher :: String -> [String]
higher name = case dropWhile (not . any (`isPrefixOf` name)) layers of
    _ : above -> concat above
    [] -> []

-- | The modules that define or re-export 'State.Run.Ask.Principal' and 'State.Run.Ask.Op'.
environment :: Set String
environment = Set.fromList ["State.Run.Ask", "State.Run.Event"]

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

-- | The kernel modules a module's source imports.
kernelImports :: String -> IO [String]
kernelImports name = filter isKernel <$> imports name

-- | Every module a kernel module's source imports; the suite runs from the package root.
imports :: String -> IO [String]
imports name = mapMaybe imported . lines <$> readFile (sourceOf name)
  where
    imported line = case words <$> stripPrefix "import " line of
        Just ("qualified" : target : _) -> Just target
        Just (target : _) -> Just target
        _ -> Nothing

-- | A module's source file; the suite runs from the package root.
sourceOf :: String -> FilePath
sourceOf name = "src/" <> map slash name <> ".hs"
  where
    slash = \case
        '.' -> '/'
        c -> c

isKernel :: String -> Bool
isKernel name = "State." `isPrefixOf` name || isEffects name || name `elem` kernelData

{- | The kernel's own @Data.*@ modules, by name: the prefix alone would take
a library's, such as @Data.Text@, for the kernel's.
-}
kernelData :: [String]
kernelData =
    [ "Data.Entity.Blob"
    , "Data.Entity.Event"
    , "Data.Entity.Run"
    , "Data.Field"
    , "Data.Payload.Blob"
    , "Data.Payload.Event"
    , "Data.Payload.Upcast"
    , "Data.Projection"
    , "Data.Projection.Context"
    , "Data.Projection.Gaps"
    , "Data.Projection.Questions"
    , "Data.Projection.Registry"
    , "Data.Projection.Runs"
    , "Data.Projection.Spans"
    , "Data.Projection.Tasks"
    , "Data.Projection.Views"
    , "Data.Report"
    , "Data.Tsv"
    ]

-- | The store: the only modules that speak SQL.
isStore :: String -> Bool
isStore = isPrefixOf "Effects.Store."

-- | The effect shell, one module.
shell :: String
shell = "State.Cli.Shell"

-- | The effects, each with its IO interpreter.
isEffects :: String -> Bool
isEffects = isPrefixOf "Effects."

-- | A library module that runs effects: files, processes, the environment, exceptions, effectful.
isEffect :: String -> Bool
isEffect name =
    any
        (`isPrefixOf` name)
        [ "Effectful"
        , "System.IO"
        , "System.Timeout"
        , "System.Process"
        , "System.Directory"
        , "System.Environment"
        , "System.Exit"
        , "Control.Exception"
        , "GHC.IO"
        , "Data.Text.IO"
        , "Database."
        ]

-- | The module a source file under @src@ defines.
moduleOf :: FilePath -> Maybe String
moduleOf file = map dot . reverse . drop 3 . reverse <$> stripPrefix "src/" file
  where
    dot = \case
        '/' -> '.'
        c -> c
