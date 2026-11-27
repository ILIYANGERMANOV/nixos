-- | The @state-hook@ command: the kernel's hooks over argv and one event on stdin.
module Main (main) where

import State.Cli.Shell qualified as Shell

main :: IO ()
main = Shell.runArgvIO Shell.hook
