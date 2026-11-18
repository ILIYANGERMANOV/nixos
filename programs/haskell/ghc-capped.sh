# shellcheck shell=bash
# The GHC the quick runners' repl runs, through `cabal repl --with-repl`: its
# heap capped at 12 GiB, so a runaway GHCi dies with "heap overflow" before it
# drains the machine's memory. Not `--repl-options`: under --enable-multi-repl
# cabal passes those to no GHC.
exec ghc +RTS -M12g -RTS "$@"
