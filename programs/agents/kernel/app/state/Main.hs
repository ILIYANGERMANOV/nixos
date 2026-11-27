-- | The @state@ command: the kernel's shell over argv.
module Main (main) where

import State.Cli.Shell qualified as Shell

main :: IO ()
main = Shell.runArgvIO Shell.main
