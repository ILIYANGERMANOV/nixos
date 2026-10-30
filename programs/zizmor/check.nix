# Audits the workflows and Dependabot config under `src`. `--offline` needs no
# token, so the audits that ask the GitHub API do not run: a pin is not checked
# to be a real commit of its action. `--strict-collection` fails on a file
# zizmor cannot parse, which it would otherwise skip with a warning.
{ pkgs, src }:
pkgs.runCommand "zizmor-check" { nativeBuildInputs = [ pkgs.zizmor ]; } ''
  cd ${src}
  zizmor --offline --strict-collection .
  touch "$out"
''
