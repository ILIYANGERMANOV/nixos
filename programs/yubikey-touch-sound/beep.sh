# shellcheck shell=bash disable=SC2154 # set by another fragment: the assembled script is checked whole
parent=$PPID
deadline=$((SECONDS + timeout_seconds))

# Take the in-flight afplay down with us instead of letting it finish.
# Never `kill 0`: this process shares its process group with ssh (and
# therefore with git and the shell's foreground job). Ask the job table, not a
# saved `$!`: bash lists a job from its fork on, so a signal landing before the
# script could save the PID still finds it, and a reaped job is not listed, so a
# recycled PID is never killed.
cleanup() {
  local running
  running=$(jobs -pr)
  if [ -n "$running" ]; then
    # shellcheck disable=SC2086 # one PID per word
    kill $running 2>/dev/null || true
  fi
  exit 0
}
trap cleanup TERM INT HUP

# Nothing outside can be relied on to stop us. A SIGKILLed ssh never
# reaches notify_complete(), and a SIGKILLed or SIGTERMed signing wrapper
# never runs its EXIT trap — either way this process is orphaned and
# would beep until logout. No trap can cover SIGKILL, so police
# ourselves: stop once the parent is gone, and in any case once the touch
# window has closed.
while [ "$SECONDS" -lt "$deadline" ]; do
  kill -0 "$parent" 2>/dev/null || exit 0

  "$afplay" -v "$volume" "$sound" >/dev/null 2>&1 &
  wait "$!" || true

  sleep "$interval" &
  wait "$!" || true
done
