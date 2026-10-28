---
name: gc
description: Run system-wide Nix garbage collection on the software factory - keep the current and previous generation of every profile, drop result links left in /tmp or ~/.cache for two days, and delete everything unreferenced. Dev shells are not rooted, so the next nix develop fetches them again from the binary caches. Use when the disk is still tight after free-disk, or the person asks for a GC.
---

# System GC

1. Run `factory-ctl gc`. It starts a root unit and returns at once.
2. Check `factory-ctl status` after a minute or two, until the last operation
   shows `gc`, and report how much it freed (in GB, as it says).
