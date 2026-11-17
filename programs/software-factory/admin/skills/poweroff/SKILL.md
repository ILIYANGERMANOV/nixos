---
name: poweroff
description: Power off the software factory server. Every live session ends and nothing comes back until someone powers the box on by hand. Use only when the person asks to power off or shut down the server.
---

# Power off

1. Run `factory-ctl status` and tell the person how many live sessions will
   end.
2. Warn them the box stays off until someone powers it on:
   - Lenovo: press the power button, or unplug and replug AC.
   - Hetzner: power it on from the Hetzner Cloud console.
3. Ask for a clear yes. Anything else: change nothing.
4. Run `factory-ctl poweroff`.
5. Tell the person this session ends with the poweroff.
