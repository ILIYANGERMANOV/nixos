-- | The @state@ command: the kernel's shell over argv.
module Main (main) where

import Data.Text qualified as Text
import State.Shell qualified as Shell
import System.Environment (getArgs)
import System.Exit (exitWith)
import System.IO (hSetEncoding, stderr, stdout, utf8)

main :: IO ()
main = do
    -- What it prints is UTF-8 whatever the locale, as in a Nix build; stdin is read as bytes.
    mapM_ (`hSetEncoding` utf8) [stdout, stderr]
    argv <- map Text.pack <$> getArgs
    exitWith =<< Shell.runShellIO (Shell.main argv)
