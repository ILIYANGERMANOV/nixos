# The `statusLine` command. Its logic is in statusline.py; test_statusline.py runs
# it against what the shell scripts it replaced printed.
{ pkgs, theme }:

# flake8 off: `python-lint` and `python-types` are the Python gate.
pkgs.writers.writePython3Bin "claude-statusline" { doCheck = false; } (
  builtins.replaceStrings
    [ "@git@" "@theme@" ]
    [ "${pkgs.git}/bin/git" theme ]
    (builtins.readFile ./statusline.py)
)
