---
name: stats
description: Show the software factory's machine stats in a short summary - RAM and disk as percent used and GB free, swap, CPU load, the agents' memory against their cap, and uptime. Use when the person asks about resources, memory, disk or load.
---

# Stats

Run `factory-ctl stats` and give it back as a few short lines, keeping the
numbers as they are. Flag anything above 85% used, and suggest:

- disk: the free-disk skill
- RAM or the agents' cap: the terminate-sessions skill, or stopping idle
  repositories with stop-repo
