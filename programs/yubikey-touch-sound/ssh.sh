# shellcheck shell=bash disable=SC2154,SC2312 # set by another fragment, and PIPESTATUS reads what the pipe would mask
export SSH_ASKPASS="$askpass"
# macOS has no X server; ssh only consults DISPLAY for X11 forwarding,
# which is off. A real value (XQuartz) wins if one is already set.
export DISPLAY="${DISPLAY:-:0}"

# Run ssh with stderr on a pipe so isatty(STDERR_FILENO) is false, while
# still delivering that stderr to the terminal. stdout and stdin are
# untouched: git owns those.
exec 3>&1
set +e
{ "$openssh" "$@" 2>&1 1>&3 3>&-; } | cat >&2
rc=${PIPESTATUS[0]}
set -e
exit "$rc"
