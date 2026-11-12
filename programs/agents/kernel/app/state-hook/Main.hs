{- | The `state-hook` command. A stub until the kernel replaces the Python
`state-hook` (#360, PR 4): until then the Python one is what agents run.
-}
module Main (main) where

import System.Exit (die)

main :: IO ()
main = die "state-hook: not built yet - the installed state-hook is the Python one"
