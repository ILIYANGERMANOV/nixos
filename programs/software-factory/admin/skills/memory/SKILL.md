---
name: memory
description: Find what holds the software factory's memory and end it - a GHCi daemon, a runaway process - before the out-of-memory killer ends a whole Remote Control server and its sessions. Use when stats shows RAM, swap or Agents high, when systemd-oomd killed a claude-rc@ server, or when a session reports slowness.
argument-hint: "[worktree or pid]"
---

# Memory

1. Run `factory-ctl mem`. It prints the biggest cgroups (each `claude-rc@`
   server, each `ghcid-*.scope` in `ghci.slice`), then the factory user's
   biggest processes with PID, RSS and command.
2. Pick the biggest that is not a Remote Control server:
   - A `ghcid-<path>.scope`: the GHCi daemon of a package, its path with `/`
     as `-` and a `-` in a name as `\x2d`
     (`ghcid-home-factory-repos-nixos-.claude-worktrees-oom.scope` is
     `~/repos/nixos/.claude/worktrees/oom`). Run
     `factory-ctl kill ghcid <worktree>`. The session can start it again; it
     only loses its warm GHCi. If several hold a lot and the person agrees,
     `factory-ctl kill ghcid --all`.
   - A process: `factory-ctl kill <pid>`. It sends TERM, then KILL after 3
     seconds, and only to the factory user's own processes.
3. Never end a Remote Control server (`claude-rc@*`) unless the person asks:
   it ends every session it carries. `factory-ctl kill` refuses one with exit 2;
   show what it printed and rerun with `--force` only on a clear yes. To end
   sessions but keep the servers, use the terminate-sessions skill.
4. Run `factory-ctl mem` again and confirm the memory came back.

Reply phone-short, for example: `Stopped GHCi in nixos/wt-oom (11.5G); RAM
now 40% used.`
