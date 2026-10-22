---
name: reboot
description: Reboot the software factory server. Every live session ends; the admin agent and every enabled repository come back on their own. Use only when the person asks to reboot, or agrees to it after a kernel update or a wedged system.
---

# Reboot

1. Run `factory-ctl status` and tell the person how many live sessions will
   end. Ask for a clear yes.
2. Run `factory-ctl reboot`. It is refused within 10 minutes of the last boot.
3. Tell the person this session ends with the reboot and the admin server is
   back in about a minute.
