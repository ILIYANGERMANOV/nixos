---
name: free-disk
description: Free disk space on the software factory - prune worktrees whose work is all pushed, delete throwaway caches and finished /qa runs, and collect unreferenced Nix store paths, while keeping the caches that make the repositories build fast. Use when the disk is filling up or the person asks to clean up.
---

# Free disk

1. Run `factory-ctl free-disk plan`. It lists, with sizes, the worktrees that
   are clean, fully pushed and have no live session; the caches; the /qa run
   directories untouched for a day, whose proof is on the PR (login state and
   scripts are never listed); the result links builds left in /tmp or
   ~/.cache for two days, each pinning its store path as a GC root; and the
   Nix store garbage. Worktrees with local work or a session are never listed.
2. Show the plan as a short list with the total, and ask once whether to go
   ahead.
3. On yes, run `factory-ctl free-disk apply` and report how much it freed and
   how much is free now.

If that is not enough, the gc skill also deletes old system generations, which
needs a root unit.
