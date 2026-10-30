# Read-only reports, sized for a phone screen.

# status: every server, its sessions and local work, then the last root
# operation, the deploy token's expiry and any skills a GC took away.
cmd_status() {
  local repo
  row "admin" "$(systemctl --user is-active "$admin_unit")" "$(sessions_under "$admin_dir" | wc -l)" 0
  for repo in $(cloned_repos); do
    row "$repo" "$(repo_state "$repo")" "$(sessions_under "$repos_dir/$repo" | wc -l)" "$(dirty_worktrees "$repo")"
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
  local active
  active=$(systemctl --user is-active "$(unit_of "$1")") || true
  case "$(is_enabled "$1" && echo enabled || echo disabled)/$active" in
    enabled/active) echo "on" ;;
    disabled/inactive) echo "off" ;;
    disabled/active) echo "on*" ;;
    */*) echo "$active" ;;
  esac
}

dirty_worktrees() {
  local wt count=0
  while read -r wt; do
    [ -z "$(local_work "$wt")" ] || count=$((count + 1))
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
    days=$(( ($(date -d "$(cat "$expires")" +%s) - $(date +%s)) / 86400 ))
    [ "$days" -ge 30 ] || echo "WARNING: the deploy token expires in $days day(s). Renew it (docs/SOFTWARE-FACTORY.md)."
  fi
}

# Links into a farm that was collected: the skills every new session lacks.
dangling_skills() {
  local names
  names=$(find -L "$HOME/.claude/skills" -mindepth 1 -maxdepth 1 -type l -printf '%f\n' 2>/dev/null | sort) || true
  if [ -z "$names" ]; then
    echo "Skills: 0 dangling links"
  else
    echo "Skills: $(echo "$names" | wc -l) dangling link(s): $(echo "$names" | head -n 5 | paste -sd ' ')"
  fi
}

# stats: the machine's headline numbers.
cmd_stats() {
  local slice
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
  printf 'CPU    load %s on %s core(s)\n' "$(cut -d ' ' -f 1 /proc/loadavg)" "$(nproc)"
  if [ -r "$slice/memory.current" ]; then
    printf 'Agents %s of %s cap\n' "$(gib "$(cat "$slice/memory.current")")" "$(gib "$(cat "$slice/memory.max")")"
  fi
  awk '{ printf "Up     %dd %dh %dm\n", $1 / 86400, $1 % 86400 / 3600, $1 % 3600 / 60 }' /proc/uptime
}

gib() {
  case "$1" in
    max) echo "no" ;;
    *) awk -v b="$1" 'BEGIN { printf "%.1f GB", b / 1073741824 }' ;;
  esac
}
