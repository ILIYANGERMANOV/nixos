# shellcheck shell=bash disable=SC2154,SC2312 # other fragments and the preamble's pipefail: the assembled script is checked whole
# Read-only reports, sized for a phone screen.

# status: every server, its sessions and local work, then the last root
# operation, the deploy token's expiry and any skills a GC took away.
cmd_status() {
  local repo state count dirty
  # is-active exits nonzero for every state but active, and still prints it.
  state=$(systemctl --user is-active "$admin_unit") || true
  count=$(sessions_under "$admin_dir" | wc -l)
  row "admin" "$state" "$count" 0
  for repo in $(cloned_repos); do
    state=$(repo_state "$repo")
    count=$(sessions_under "$repos_dir/$repo" | wc -l)
    dirty=$(dirty_worktrees "$repo")
    row "$repo" "$state" "$count" "$dirty"
  done
  echo
  last_op
  dangling_skills
}

row() {
  local name="$1" state="$2" sessions="$3" dirty="$4" extra=""
  [ "$dirty" -eq 0 ] || extra="  $dirty worktree(s) with local work"
  printf '%-18s %-8s %s session(s)%s\n' "$name" "$state" "$sessions" "$extra"
}

# "on" and "off" when the server matches the enabled set; otherwise systemd's
# own word, such as failed or activating, which is what needs attention.
repo_state() {
  local unit active
  unit=$(unit_of "$1")
  active=$(systemctl --user is-active "$unit") || true
  # shellcheck disable=SC2310 # a predicate
  case "$(is_enabled "$1" && echo enabled || echo disabled)/$active" in
    enabled/active) echo "on" ;;
    disabled/inactive) echo "off" ;;
    disabled/active) echo "on*" ;;
    *) echo "$active" ;;
  esac
}

dirty_worktrees() {
  local wt work count=0
  # shellcheck disable=SC2312 # a failed listing has always read as no worktrees
  while read -r wt; do
    work=$(local_work "$wt")
    [ -z "$work" ] || count=$((count + 1))
  done < <(worktrees_of "$1")
  echo "$count"
}

# Written by the root units (programs/software-factory/ops), readable by all.
last_op() {
  local file="$ops_state_dir/last.json" expires days
  if [ -r "$file" ]; then
    jq -r '"Last \(.op): \(.state) \(.sha // "" | .[0:7]) at \(.at)\n  \(.message)"' "$file"
  else
    echo "No deploy, rollback or GC has run yet."
  fi
  expires="$ops_state_dir/token-expires"
  if [ -r "$expires" ]; then
    days=$(( ($(date -d "$(<"$expires")" +%s) - $(date +%s)) / 86400 ))
    [ "$days" -ge 30 ] || echo "WARNING: the deploy token expires in $days day(s). Renew it (docs/SOFTWARE-FACTORY.md)."
  fi
}

# Links into a farm that was collected: the skills every new session lacks.
dangling_skills() {
  local names count first
  names=$(find -L "$HOME/.claude/skills" -mindepth 1 -maxdepth 1 -type l -printf '%f\n' 2>/dev/null | sort) || true
  if [ -z "$names" ]; then
    echo "Skills: 0 dangling links"
  else
    count=$(wc -l <<<"$names")
    # A here-string, because under pipefail a writer that head outruns would fail.
    first=$(head -n 5 <<<"$names" | paste -sd ' ')
    echo "Skills: $count dangling link(s): $first"
  fi
}

# stats: the machine's headline numbers.
cmd_stats() {
  local slice load cores used cap
  slice="/sys/fs/cgroup/user.slice/user-$(id -u).slice"
  awk '
    /^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 }
    /^SwapTotal:/ { st = $2 } /^SwapFree:/ { sf = $2 }
    END {
      printf "RAM    %3d%% used  (%.1f GB free of %.1f)\n", (t - a) * 100 / t, a / 1048576, t / 1048576
      if (st > 0) printf "Swap   %3d%% used  (%.1f GB of %.1f)\n", (st - sf) * 100 / st, (st - sf) / 1048576, st / 1048576
    }' /proc/meminfo
  df -B1 --output=size,avail / | awk 'NR == 2 {
    printf "Disk   %3d%% used  (%.0f GB free of %.0f)\n", ($1 - $2) * 100 / $1, $2 / 1e9, $1 / 1e9 }'
  load=$(cut -d ' ' -f 1 /proc/loadavg) || true
  cores=$(nproc) || true
  printf 'CPU    load %s on %s core(s)\n' "$load" "$cores"
  if [ -r "$slice/memory.current" ]; then
    used=$(gib "$(<"$slice/memory.current")")
    cap=$(gib "$(<"$slice/memory.max")")
    printf 'Agents %s of %s cap\n' "$used" "$cap"
  fi
  awk '{ printf "Up     %dd %dh %dm\n", $1 / 86400, $1 % 86400 / 3600, $1 % 3600 / 60 }' /proc/uptime
}

gib() {
  case "$1" in
    max) echo "no" ;;
    *) awk -v b="$1" 'BEGIN { printf "%.1f GB", b / 1073741824 }' ;;
  esac
}
