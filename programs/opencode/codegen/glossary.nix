# The lead's AGENTS.md ends with this: the instructions and skills name Claude
# Code's tools, and stay as they are; OpenCode's names come from tools.nix.
{ pkgs, lib }:

let
  tools = import ./tools.nix;
  name = capability: lib.concatMapStringsSep " or " (tool: "`${tool}`") tools.${capability}.tools;
in
# It opens with a blank line: the lead's render ends in one newline.
pkgs.writeText "opencode-glossary.md" ''

  ## OpenCode

  This session runs in OpenCode, not Claude Code. Your instructions and skills
  name Claude Code's tools. Read each as its OpenCode tool:

  | Claude Code | OpenCode |
  |---|---|
  | `Agent` (`subagent_type`) | ${name "delegate"} with the same `subagent_type` |
  | `Agent` with `run_in_background` | ${name "delegate"} with `background: true` |
  | `SendMessage` to an agent | ${name "delegate"} with that agent's `task_id` |
  | `Skill` | ${name "skill"} |
  | `Bash` | ${name "shell"} |
  | `Read`, `Edit`, `Write` | ${name "read"}, ${name "edit"}, ${name "write"} |
  | `WebFetch`, `WebSearch` | ${name "web"} |
  | `Bash` with `run_in_background` | ${name "shell"} in the foreground, with a timeout |
  | `SubagentHandback` | none: your last reply is your hand-back |
  | `TaskStop` | none: no agent can stop another |
  | `PushNotification`, `add_repo`, `subscribe_pr_activity` | none: skip that step |

  A wait such as `gh pr checks --watch` runs in the foreground, with a timeout.
''
