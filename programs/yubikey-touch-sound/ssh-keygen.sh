# shellcheck shell=bash disable=SC2154 # set by another fragment: the assembled script is checked whole
signing=0
prev=""
for arg in "$@"; do
  if [ "$prev" = "-Y" ] && [ "$arg" = "sign" ]; then
    signing=1
    break
  fi
  prev="$arg"
done

if [ "$signing" -eq 0 ]; then
  exec "$openssh_keygen" "$@"
fi

# stdout carries the signature back to git — keep the alert off it, and
# off stdin too, which is the pipe git streams the payload down.
"$beep" </dev/null >/dev/null 2>&1 &
loop=$!
# Best-effort: an untrapped signal skips this, so beep also stops itself.
trap 'kill "$loop" 2>/dev/null || true' EXIT

set +e
"$openssh_keygen" "$@"
rc=$?
set -e
exit "$rc"
