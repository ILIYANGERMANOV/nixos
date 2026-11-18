---
name: stats
description: Show the software factory's machine health - RAM, swap, disk, CPU load, the agents' memory cap, CPU and NVMe temperature, fan, heat slowdowns and battery - each with a normal, warning or critical state and an overall verdict. Use when the person asks about resources, memory, disk, load, temperature, fan, heat or battery.
---

# Stats

Run `factory-ctl stats`. Each row ends in its state (`normal`, `warning` or
`critical`) and the last line is the verdict (`Health OK`, `Health WARNING -
<rows>` or `Health CRITICAL - <rows>`). The script decides every state: never
re-judge a number yourself.

Reply phone-short:

1. The verdict first, in one line: ✅ OK, ⚠️ WARNING or 🔴 CRITICAL.
2. A table of every row, numbers as printed, state as ✅ normal, ⚠️ warning,
   🔴 critical:

   | Item | Value | State |
   |---|---|---|
   | RAM | 4% used, 59.9 GB free of 62.5 | ✅ |

   Then uptime on one line.
3. For each warning or critical row only, one line on what to do:

   - RAM, swap or Agents: the memory skill, to find and end what holds it;
     then terminate-sessions, or stop-repo for an idle repository
   - Disk: the free-disk skill
   - CPU load: terminate-sessions or stop-repo for the busiest repository
   - CPU temp, NVMe temp, Fan or Throttled: check the airflow - a hard
     surface, room around the vents, nothing on the lid; a stopped fan under
     load is a hardware fault, so ease the load until it is looked at.
     Throttled warns only when the CPU slowed for heat since the last stats
     run (`since boot, +N`); a large total since boot alone is history
   - Battery: plug in the AC; `not charging` while plugged in means the
     charger or its cable
   - Bat health: the battery is worn; plan a replacement

A row the machine has no sensor for is simply absent: do not mention it. A
virtual machine, such as the Hetzner factory, has no temperature, fan,
slowdown or battery rows at all; that is expected, never a problem.
