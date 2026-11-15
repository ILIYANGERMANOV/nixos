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
  local active
  # shellcheck disable=SC2310 # is-active exits nonzero for every state but active
  active=$(repo_unit is-active "$1") || true
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
    days=$((($(date -d "$(<"$expires")" +%s) - $(date +%s)) / 86400))
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

# stats: the machine's headline numbers, each with a state - normal, warning
# or critical - then the verdict, the worst state and every row that is not
# normal. Rows are "name<TAB>value<TAB>detail<TAB>state" until printed.
cmd_stats() {
  local rows
  rows=$(stat_rows)
  awk -F '\t' '{ printf "%-10s %-10s %-26s %s\n", $1, $2, $3, $4 }' <<<"$rows"
  awk '{ printf "%-10s %dd %dh %dm\n", "Up", $1 / 86400, $1 % 86400 / 3600, $1 % 3600 / 60 }' "$kernel_root/proc/uptime"
  awk -F '\t' '
    $4 == "critical" { critical = 1 }
    $4 != "normal" { reasons = reasons sep $1 " " $2; sep = ", " }
    END { printf "%-10s %s\n", "Health", critical ? "CRITICAL - " reasons : reasons != "" ? "WARNING - " reasons : "OK" }
  ' <<<"$rows"
}

# Where /proc and /sys are read from: the suites point it at a fake tree.
kernel_root="${FACTORY_KERNEL_ROOT:-}"

# A sensor the machine lacks drops its row; it never fails the command. A
# rule that needs the CPU's temperature gets "none" without one.
stat_rows() {
  local cpu package crit core
  memory_rows
  disk_row
  load_row
  agents_row
  # "package crit hottest-core" in millidegrees, or nothing without coretemp.
  cpu=$(cpu_temps)
  read -r package crit core <<<"${cpu:-none none none}"
  [ "$package" = none ] || cpu_temp_row "$package" "$crit" "$core"
  nvme_rows
  fan_row "$package"
  throttle_row "$package"
  battery_rows
}

# stat_row <name> <value> <detail> <state command...>: the command prints the state.
stat_row() {
  printf '%s\t%s\t%s\t' "$1" "$2" "$3"
  "${@:4}"
}

memory_rows() {
  local name pct detail
  # shellcheck disable=SC2312 # a missing meminfo is a broken kernel, not a missing sensor
  while IFS=$'\t' read -r name pct detail; do
    case "$name" in
      RAM) stat_row "$name" "$pct% used" "$detail" capacity_state "$pct" ;;
      Swap) stat_row "$name" "$pct% used" "$detail" swap_state "$pct" ;;
      *) ;;
    esac
  done < <(awk '
    /^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 }
    /^SwapTotal:/ { st = $2 } /^SwapFree:/ { sf = $2 }
    END {
      printf "RAM\t%d\t%.1f GB free of %.1f\n", (t - a) * 100 / t, a / 1048576, t / 1048576
      if (st > 0) printf "Swap\t%d\t%.1f GB of %.1f\n", (st - sf) * 100 / st, (st - sf) / 1048576, st / 1048576
    }' "$kernel_root/proc/meminfo")
}

# The real root filesystem even under a fake kernel root: df cannot be faked.
disk_row() {
  local usage pct detail
  usage=$(df -B1 --output=size,avail / | awk 'NR == 2 {
    printf "%d %.0f GB free of %.0f\n", ($1 - $2) * 100 / $1, $2 / 1e9, $1 / 1e9 }')
  read -r pct detail <<<"$usage"
  stat_row Disk "$pct% used" "$detail" capacity_state "$pct"
}

load_row() {
  local load cores
  load=$(cut -d ' ' -f 1 "$kernel_root/proc/loadavg") || true
  cores=$(nproc) || true
  stat_row CPU "load $load" "on $cores core(s)" load_state "$load" "$cores"
}

agents_row() {
  local slice used cap used_gb cap_gb
  slice="$kernel_root/sys/fs/cgroup/user.slice/user-$(id -u).slice"
  [ -r "$slice/memory.current" ] || return 0
  used=$(<"$slice/memory.current")
  cap=$(<"$slice/memory.max")
  used_gb=$(gib "$used")
  case "$cap" in
    max) stat_row Agents "$used_gb" "no cap" echo normal ;;
    *)
      cap_gb=$(gib "$cap")
      stat_row Agents "$((used * 100 / cap))% of cap" "$used_gb of $cap_gb" capacity_state "$((used * 100 / cap))"
      ;;
  esac
}

gib() { awk -v b="$1" 'BEGIN { printf "%.1f GB", b / 1073741824 }'; }

# The hottest package with its crit, and the hottest core (or "none"), from
# coretemp. Silent without a package sensor, as on a VM.
cpu_temps() {
  local dir label input package="" crit="" core=""
  for dir in $(hwmon coretemp); do
    for label in "$dir"/temp*_label; do
      input=$(sensor "${label%_label}_input")
      case "$(sensor "$label")/$input" in
        */) ;;
        "Package id "*)
          if [ -z "$package" ] || [ "$input" -gt "$package" ]; then
            package=$input
            crit=$(sensor "${label%_label}_crit")
          fi
          ;;
        "Core "*) if [ -z "$core" ] || [ "$input" -gt "$core" ]; then core=$input; fi ;;
        *) ;;
      esac
    done
  done
  [ -z "$package" ] || echo "$package ${crit:-none} ${core:-none}"
}

cpu_temp_row() {
  local package="$1" crit="$2" core="$3" detail=""
  [ "$core" = none ] || detail="hottest core $((core / 1000)) C"
  stat_row "CPU temp" "$((package / 1000)) C" "$detail" cpu_temp_state "$package" "$crit"
}

# The Composite sensor of every drive, against the drive's own max (WCTEMP).
nvme_rows() {
  local dir label name temp max
  for dir in $(hwmon nvme); do
    for label in "$dir"/temp*_label; do
      name=$(sensor "$label")
      temp=$(sensor "${label%_label}_input")
      [ "$name" = Composite ] && [ -n "$temp" ] || continue
      max=$(sensor "${label%_label}_max")
      stat_row "NVMe temp" "$((temp / 1000)) C" "${max:+max $((max / 1000)) C}" nvme_temp_state "$temp" "${max:-none}"
    done
  done
}

# thinkpad_acpi's fan; pwm1_enable is 2 under the firmware's automatic control.
fan_row() {
  local cpu="$1" dir rpm control mode
  for dir in $(hwmon thinkpad); do
    rpm=$(sensor "$dir/fan1_input")
    [ -n "$rpm" ] || continue
    control=$(sensor "$dir/pwm1_enable")
    case "$control" in
      0) mode="full speed" ;;
      1) mode="manual" ;;
      2) mode="auto" ;;
      *) mode="" ;;
    esac
    stat_row Fan "$rpm RPM" "$mode" fan_state "$rpm" "$cpu"
  done
}

# Every CPU of a package reports the same package count, and hyperthread
# siblings the same core count, so each is taken once per package or core.
throttle_row() {
  local cpu="$1" dir count package_id core package=0 cores=0 found=0
  local -A counted=()
  for dir in "$kernel_root"/sys/devices/system/cpu/cpu*/thermal_throttle; do
    [ -d "$dir" ] || continue
    found=1
    count=$(sensor "$dir/package_throttle_count")
    [ "${count:-0}" -le "$package" ] || package=$count
    package_id=$(sensor "$dir/../topology/physical_package_id")
    core=$(sensor "$dir/../topology/core_id")
    core="$package_id/$core"
    [ "$core" != / ] || core=$dir
    [ -z "${counted[$core]:-}" ] || continue
    counted[$core]=1
    count=$(sensor "$dir/core_throttle_count")
    cores=$((cores + ${count:-0}))
  done
  [ "$found" -eq 1 ] || return 0
  count=$((package + cores))
  stat_row Throttled "$count times" "since boot" throttle_state "$count" "$cpu"
}

# The first battery only: the factories have one at most.
battery_rows() {
  local dir type status capacity full design cycles detail
  for dir in "$kernel_root"/sys/class/power_supply/*; do
    type=$(sensor "$dir/type")
    [ "$type" = Battery ] || continue
    status=$(sensor "$dir/status")
    capacity=$(sensor "$dir/capacity")
    case "$status" in
      Discharging) detail="on battery" ;;
      *) detail="on AC, ${status,,}" ;;
    esac
    [ -z "$capacity" ] || stat_row Battery "$capacity%" "$detail" charge_state "$status" "$capacity"
    full=$(sensor "$dir/energy_full")
    design=$(sensor "$dir/energy_full_design")
    if [ -z "$full" ]; then
      full=$(sensor "$dir/charge_full")
      design=$(sensor "$dir/charge_full_design")
    fi
    cycles=$(sensor "$dir/cycle_count")
    [ -z "$full" ] || [ "${design:-0}" -eq 0 ] ||
      stat_row "Bat health" "$((full * 100 / design))%" "${cycles:+$cycles cycles}" battery_health_state "$((full * 100 / design))"
    return 0
  done
}

# hwmon numbers follow probe order, which can change across boots; the name
# is stable.
hwmon() {
  local dir name
  for dir in "$kernel_root"/sys/class/hwmon/*; do
    name=$(sensor "$dir/name")
    [ "$name" != "$1" ] || echo "$dir"
  done
}

# A sensor's value, or nothing: some exist but fail to read (ENXIO).
sensor() { cat "$1" 2>/dev/null || true; }

# ─── States: value in, state out. Temperatures are in millidegrees C. ───────

# RAM, disk and the agents' memory, in percent used.
capacity_state() { at_or_above "$1" 85 95; }

swap_state() { at_or_above "$1" 50 80; }

# The 1-minute load ("1.89") against the core count: above it, work waits.
load_state() {
  local hundredths=$((10#${1%.*} * 100 + 10#${1#*.}))
  at_or_above "$hundredths" $(($2 * 100 + 1)) $(($2 * 200 + 1))
}

# Critical 5 C below the sensor's crit, where the CPU starts cutting its clock,
# when that comes before 95 C.
cpu_temp_state() {
  local critical=95000
  [ "$2" = none ] || [ $(($2 - 5000)) -ge "$critical" ] || critical=$(($2 - 5000))
  at_or_above "$1" 85000 "$critical"
}

# Without the drive's max, only the early warning applies.
nvme_temp_state() {
  case "$2" in
    none) if (($1 >= 70000)); then echo warning; else echo normal; fi ;;
    *) at_or_above "$1" 70000 "$2" ;;
  esac
}

# Any speed is fine on its own; a stopped fan under a hot CPU is not.
fan_state() {
  case "$1/$2" in
    0/none) echo normal ;;
    0/*) at_or_above "$2" 60000 80000 ;;
    *) echo normal ;;
  esac
}

throttle_state() {
  case "$1/$2" in
    0/*) echo normal ;;
    */none) echo warning ;;
    *) at_or_above "$2" 0 95000 ;;
  esac
}

# Not charging at all means the AC brings nothing, so a low charge warns there
# too; only a discharging battery runs out.
charge_state() {
  case "$1" in
    Discharging) below "$2" 50 20 ;;
    "Not charging") below "$2" 50 0 ;;
    *) echo normal ;;
  esac
}

# Full capacity against design, in percent.
battery_health_state() { below "$1" 80 60; }

# at_or_above <value> <warning from> <critical from>
at_or_above() {
  if (($1 >= $3)); then
    echo critical
  elif (($1 >= $2)); then
    echo warning
  else
    echo normal
  fi
}

# below <value> <warning under> <critical under>
below() {
  if (($1 < $3)); then
    echo critical
  elif (($1 < $2)); then
    echo warning
  else
    echo normal
  fi
}
