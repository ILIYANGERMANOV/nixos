# `ctx`: a branch diff written once to a cached folder, for every agent to read.
# Its logic is in ctx.py; test_ctx.py runs it on temp git repos. It runs the
# session's own git, the one the agent already works with.
{ pkgs }:

# flake8 off: `python-lint` and `python-types` are the Python gate.
pkgs.writers.writePython3Bin "ctx" { doCheck = false; } (builtins.readFile ./ctx.py)
