# claude-kategory builds, so its relocated files name no ~/.claude path
# (relocate.sh) and its wrapper passes shellcheck, and its `--settings` denies
# reading the login in both ~/.claude and ~/.claude-kategory.
{ pkgs, claude-kategory }:

pkgs.runCommand "kategory-check" { nativeBuildInputs = [ pkgs.jq ]; } ''
  : ${claude-kategory}
  jq -e '.permissions.deny
    | index("Read(~/.claude/.credentials.json)")
      and index("Read(~/.claude-kategory/.credentials.json)")' \
    ${claude-kategory.settingsFile}
  touch "$out"
''
