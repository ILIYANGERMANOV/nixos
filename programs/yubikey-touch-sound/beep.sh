# shellcheck shell=bash disable=SC2154 # set by another fragment: the assembled script is checked whole
parent=$PPID
deadline=$(( SECONDS + timeout_seconds ))
child=""

# Take the in-flight afplay down with us instead of letting it finish.
# Never `kill 0`: this process shares its process group with ssh (and
# therefore with git and the shell's foreground job).
cleanup() {
  if [ -n "$child" ]; then
    kill "$child" 2>/dev/null || true
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
  child=$!
  wait "$child" || true
  child="" # reaped — the PID can be recycled, so never kill it again

  sleep "$interval" &
  child=$!
  wait "$child" || true
  child=""
done
