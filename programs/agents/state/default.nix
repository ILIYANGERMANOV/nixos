# `state`: the engineer flow as an append-only event log, folded into the
# current state, with the next arrow advised. Its logic is in state.py;
# test_state.py runs it on temp git repos. It runs the session's own git, the
# one the agent already works with.
{ pkgs }:

# flake8 off: `python-lint` and `python-types` are the Python gate.
pkgs.writers.writePython3Bin "state" { doCheck = false; } (builtins.readFile ./state.py)
