{- | The `state` command. A stub until the kernel replaces the Python `state`
(#360, PR 4): until then the Python one is what agents run.
-}
module Main (main) where

import System.Exit (die)

main :: IO ()
main = die "state: not built yet - the installed state is the Python one"
