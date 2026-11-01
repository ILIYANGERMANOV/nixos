#!/usr/bin/env bash
set -euo pipefail
mode=$1
case "$mode" in
  concise | detailed) ;;
  *)
    echo "ERROR: expected 'concise' or 'detailed', got '$mode'" >&2
    exit 1
    ;;
esac

# The remote side runs without -e or pipefail, so one failing section
# still leaves the others printed. $mode is one of two fixed words by
# now, so it is safe in the remote command line.
ssh -o ConnectTimeout=10 factory@software-factory "bash -s -- $mode" <<'EOF' || {
set -u

main() {
  usage
  section "Remote Control"; remote_control
  case "$1" in
    concise) ;;
    detailed)
      section "Recent branches"; branches
      section "Problems";        problems
      section "Top memory";      top_memory
      ;;
  esac
}

section() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

# "Used" RAM is what cannot be reclaimed: total minus available, so page
# cache does not count.
usage() {
  local ram disk
  ram=$(awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } END { printf "%d%%", (t - a) * 100 / t }' /proc/meminfo)
  disk=$(df --output=pcent / | tail -n 1 | tr -d ' ')
  printf '\033[1mRAM %s used  ·  Disk %s used\033[0m\n' "$ram" "$disk"
}

# A session is a `claude --print --sdk-url` process; its working directory
# is a worktree under the repository it serves.
remote_control() {
  local unit repo state sessions
  for unit in $(systemctl --user list-units 'claude-rc@*' --all --no-legend --plain | awk '{print $1}'); do
    repo=${unit#claude-rc@}; repo=${repo%.service}
    state=$(systemctl --user is-active "$unit")
    sessions=$(session_count "$repo")
    printf '%-20s %-10s %s session(s)\n' "$repo" "$state" "$sessions"
  done
}

session_count() {
  local pid count=0
  for pid in $(pgrep -u "$(id -u)" -f -- '--sdk-url'); do
    case "$(readlink "/proc/$pid/cwd" 2>/dev/null)" in
      "$HOME/repos/$1" | "$HOME/repos/$1"/*) count=$((count + 1)) ;;
    esac
  done
  echo "$count"
}

branches() {
  local dir
  for dir in "$HOME"/repos/*/; do
    printf '%s\n' "$(basename "$dir")"
    git -C "$dir" for-each-ref --sort=-committerdate --count=3 \
      --format='  %(committerdate:relative)  %(refname:short)  %(subject)' refs/heads
  done
}

# Failed user units, and Remote Control errors from the last hour.
problems() {
  local found
  found=$(
    systemctl --user --failed --no-legend --plain
    journalctl --user --unit='claude-rc@*' --since -1h --no-pager -o short -q \
      | grep -aiE 'error|fatal|denied|killed' | tail -n 10
  )
  printf '%s\n' "${found:-none}"
}

top_memory() {
  ps -eo rss=,args= --sort=-rss | head -n 8 | awk '{ printf "%7.0fM  %s\n", $1 / 1024, substr($0, index($0, $2), 100) }'
}

main "$1"
EOF
  status=$?
  [ "$status" -ne 255 ] || echo "ERROR: could not reach software-factory. Is Tailscale up? (just macos-main-tailscale-up)" >&2
  exit "$status"
}
