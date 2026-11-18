# shellcheck shell=bash disable=SC2154,SC2312 # other fragments and the preamble's pipefail: the assembled script is checked whole
# What holds the memory, and ending it: a process of the factory user, or the
# GHCi daemons, which run in their own scopes in ghci.slice named
# ghcid-<systemd-escape --path of the package dir>.scope (programs/haskell).
# check.nix pins these names to ghcid.sh and the factory module.

readonly mem_rows=10
readonly kill_grace_tenths=30 # how long a process gets after TERM, before KILL

# mem: the biggest cgroups (servers, GHCi scopes), then the biggest processes.
cmd_mem() {
  echo "Cgroups by memory:"
  # awk, not head: head exiting early fails the producer under pipefail.
  systemd-cgtop -m -b -1 --depth=4 "/user.slice/user-$UID.slice" | awk -v n="$((mem_rows + 1))" 'NR <= n'
  echo
  echo "Processes by memory:"
  ps -u "$EUID" -o pid=,rss=,args= --sort=-rss | awk -v n="$mem_rows" '
    BEGIN { printf "%7s %8s  %s\n", "PID", "RSS", "COMMAND" }
    NR <= n {
      pid = $1; rss = $2; $1 = $2 = ""; sub(/^ +/, "")
      printf "%7d %5d MB  %.60s\n", pid, rss / 1024, $0
    }'
}

# kill [--force] <pid> | kill ghcid <worktree>|--all
cmd_kill() {
  parse_force "$@"
  case "${args[0]:-}" in
    ghcid)
      [ "${#args[@]}" -eq 2 ] && [ -n "${args[1]}" ] || kill_usage
      stop_ghcid "${args[1]}"
      ;;
    "" | *[!0-9]*) kill_usage ;;
    *)
      [ "${#args[@]}" -eq 1 ] || kill_usage
      kill_pid "${args[0]}"
      ;;
  esac
}

kill_usage() { die "usage: kill [--force] <pid> | kill ghcid <worktree>|--all"; }

# systemd stops a scope's whole process tree, TERM then KILL.
stop_ghcid() {
  case "$1" in
    --all)
      systemctl --user stop ghci.slice
      echo "Stopped every GHCi daemon."
      ;;
    *)
      local dir scopes units
      dir=$(realpath -m -- "$1")
      scopes=$(ghcid_scopes "$dir")
      if [ -n "$scopes" ]; then
        mapfile -t units <<<"$scopes"
        systemctl --user stop "${units[@]}"
      fi
      echo "Stopped the GHCi daemons of $1, if any ran."
      ;;
  esac
}

# The running scopes of the packages in worktree $1: ghcid-<worktree>.scope at
# its root, ghcid-<worktree>-*.scope below it. systemd-escape turns a `-` in a
# name into \x2d, so no sibling worktree matches. A Claude worktree nests in
# the main checkout (.claude/worktrees/<name>) but is not part of it: its
# scopes stay. The unit goes to awk through the environment: -v would turn
# its \x2d into a dash.
ghcid_scopes() {
  local unit
  unit="ghcid-$(systemd-escape --path "$1")"
  systemctl --user list-units --plain --no-legend "$unit.scope" "$unit-*.scope" |
    unit=$unit awk 'index(substr($1, length(ENVIRON["unit"]) + 1), "-.claude-worktrees-") == 0 { print $1 }'
}

# Only the factory user's own processes, and never a Remote Control server
# unless forced: ending one ends every session it carries.
kill_pid() {
  local pid="$1" uid servers
  uid=$(awk '/^Uid:/ { print $2 }' "$kernel_root/proc/$pid/status" 2>/dev/null) || true
  case "$uid" in
    "") die "no process $pid" ;;
    "$EUID") ;;
    *) die "process $pid belongs to uid $uid, not the factory user" ;;
  esac
  servers=$(rc_server_pids)
  if [ "$force" -eq 0 ] && grep -qxF "$pid" <<<"$servers"; then
    refuse "process $pid is a Remote Control server; killing it ends all its sessions"
  fi

  kill -TERM "$pid"
  local _
  for _ in $(seq "$kill_grace_tenths"); do
    # shellcheck disable=SC2310 # a predicate
    if ! running "$pid"; then
      echo "Killed $pid (TERM)."
      return 0
    fi
    sleep 0.1
  done
  kill -KILL "$pid"
  echo "Killed $pid (KILL, it ignored TERM)."
}

rc_server_pids() { systemctl --user show -p MainPID --value 'claude-rc@*.service' "$admin_unit"; }

# A zombie has ended: it holds no memory, only its parent's wait.
# The state follows the last ")": the name before it may hold spaces.
running() {
  local stat
  stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  stat="${stat##*) }"
  [ "${stat%% *}" != Z ]
}
