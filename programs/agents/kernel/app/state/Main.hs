-- | The @state@ command: the kernel's shell over argv.
module Main (main) where

import Data.Text qualified as Text
import State.Shell qualified as Shell
import System.Environment (getArgs)
import System.IO (hSetEncoding, stderr, stdin, stdout, utf8)

main :: IO ()
main = do
    -- The log and hand-backs are UTF-8 whatever the locale, as in a Nix build.
    mapM_ (`hSetEncoding` utf8) [stdin, stdout, stderr]
    Shell.main . map Text.pack =<< getArgs
