#!/usr/bin/env bats
# shellcheck disable=SC2154,SC2312 # test_helper and check.nix set the variables, and a masked failure fails the assertion around it

load ../test_helper

@test "status: one row per server, then the last root operation and token warning" {
  clone_repo origin
  wt=$(add_worktree origin dirty)
  touch "$wt/new-file"
  factory-ctl start origin
  clone_repo parked
  mkdir -p "$work/ops"
  jq -n '{op: "deploy", state: "success", sha: "abcdef1234567", message: "Deployed", at: "now"}' >"$work/ops/last.json"
  date -d '+5 days' '+%F %T UTC' >"$work/ops/token-expires"

  factory-ctl status >"$work/out"

  grep -Eq '^admin +inactive +0 session' "$work/out" || fail "no admin row"
  grep -Eq '^origin +on +0 session.*1 worktree' "$work/out" || fail "origin's row is wrong"
  grep -Eq '^parked +off ' "$work/out" || fail "parked's row is wrong"
  grep -q 'Last deploy: success abcdef1' "$work/out" || fail "the last deploy is missing"
  grep -q 'WARNING: the deploy token expires' "$work/out" || fail "no expiry warning"
}

# ─── stats ───────────────────────────────────────────────────────────────────

# A KVM guest such as the Hetzner factory: /proc and the agents' cgroup, and a
# /sys with no hwmon device, no thermal_throttle and no battery.
vm_kernel() {
  export FACTORY_KERNEL_ROOT="$work/kernel"
  rm -rf "$FACTORY_KERNEL_ROOT"
  mkdir -p "$FACTORY_KERNEL_ROOT/proc" "$FACTORY_KERNEL_ROOT/sys/class/hwmon" \
    "$FACTORY_KERNEL_ROOT/sys/class/power_supply" "$FACTORY_KERNEL_ROOT/sys/devices/system/cpu/cpu0"
  meminfo 9000 10000 9000
  echo "0.00 0.00 0.00 1/100 1234" >"$FACTORY_KERNEL_ROOT/proc/loadavg"
  echo "4000.00 1000.00" >"$FACTORY_KERNEL_ROOT/proc/uptime"
  sensor "$agents/memory.current" 1073741824
  sensor "$agents/memory.max" 10737418240
}

# meminfo <available kB> <swap total kB> <swap free kB>, of 10000 kB of RAM
meminfo() {
  printf 'MemTotal: 10000 kB\nMemAvailable: %s kB\nSwapTotal: %s kB\nSwapFree: %s kB\n' "$@" >"$FACTORY_KERNEL_ROOT/proc/meminfo"
}

agents="fs/cgroup/user.slice/user-$(id -u).slice"

# The ThinkPad: the VM's files plus its sensors, every row normal, with hwmon
# numbers out of order so only the names find them.
thinkpad_kernel() {
  vm_kernel
  sensor class/hwmon/hwmon2/name coretemp
  sensor class/hwmon/hwmon2/temp1_label "Package id 0"
  sensor class/hwmon/hwmon2/temp1_input 67000
  sensor class/hwmon/hwmon2/temp1_crit 100000
  sensor class/hwmon/hwmon2/temp2_label "Core 0"
  sensor class/hwmon/hwmon2/temp2_input 58000
  sensor class/hwmon/hwmon7/name nvme
  sensor class/hwmon/hwmon7/temp1_label Composite
  sensor class/hwmon/hwmon7/temp1_input 35000
  sensor class/hwmon/hwmon7/temp1_max 77850
  sensor class/hwmon/hwmon4/name thinkpad
  sensor class/hwmon/hwmon4/fan1_input 1955
  sensor class/hwmon/hwmon4/pwm1_enable 2
  sensor devices/system/cpu/cpu0/thermal_throttle/core_throttle_count 0
  sensor devices/system/cpu/cpu0/thermal_throttle/package_throttle_count 0
  sensor devices/system/cpu/cpu0/topology/physical_package_id 0
  sensor devices/system/cpu/cpu0/topology/core_id 0
  sensor class/power_supply/BAT0/type Battery
  sensor class/power_supply/BAT0/status "Not charging"
  sensor class/power_supply/BAT0/capacity 79
  sensor class/power_supply/BAT0/energy_full 69310000
  sensor class/power_supply/BAT0/energy_full_design 68000000
  sensor class/power_supply/BAT0/cycle_count 106
}

# sensor <path under /sys> <value>
sensor() {
  mkdir -p "$(dirname "$FACTORY_KERNEL_ROOT/sys/$1")"
  echo "$2" >"$FACTORY_KERNEL_ROOT/sys/$1"
}

# stats_cleanly [<what is broken>]: stats exits 0 with nothing on stderr, its
# output in $work/out.
stats_cleanly() {
  factory-ctl stats >"$work/out" 2>"$work/err" || fail_showing "$work/err" "stats failed${1:+ with $1}"
  [ ! -s "$work/err" ] || fail_showing "$work/err" "stats wrote errors${1:+ with $1}"
}

# each_broken <find type> <break command>: breaks every file or directory of
# the ThinkPad's tree in turn. Each time stats runs cleanly and its verdict
# stays what the whole tree gives: a broken sensor drops its row, nothing more.
each_broken() {
  local paths path verdict
  thinkpad_kernel
  stats_cleanly
  verdict=$(tail -n 1 "$work/out")
  paths=$(cd "$FACTORY_KERNEL_ROOT" && find . -mindepth 1 -type "$1" | sort)
  while read -r path; do
    thinkpad_kernel
    "$2" "$FACTORY_KERNEL_ROOT/$path"
    stats_cleanly "$2 $path"
    [ "$(tail -n 1 "$work/out")" = "$verdict" ] || fail_showing "$work/out" "$2 $path changed the verdict"
  done <<<"$paths"
}

removed() { rm -rf "$1"; }
# Reading a directory fails as a sysfs file failing with ENXIO does. chmod 000
# would not stop a build running as root.
unreadable() { rm "$1" && mkdir "$1"; }
emptied() { : >"$1"; }
not_a_number() { echo "N/A" >"$1"; }

# The state a stats row ends with; names are the first 10 columns.
state_of() {
  factory-ctl stats | awk -v row="$1" '{ name = substr($0, 1, 10); sub(/ +$/, "", name) } name == row { print $NF }'
}

is_state() {
  local actual
  actual=$(state_of "$1")
  [ "$actual" = "$2" ] || fail "$1 is '$actual', expected $2"
}

@test "stats: an all-normal machine reads Health OK" {
  thinkpad_kernel
  [ "$(state_of Disk)" = normal ] || skip "the build machine's own disk is not normal"

  stats_cleanly

  for row in RAM Swap Disk CPU Agents "CPU temp" "NVMe temp" Fan Throttled Battery "Bat health"; do
    grep -Eq "^$row +.* normal$" "$work/out" || fail_showing "$work/out" "no normal $row row"
  done
  grep -Eq '^Up +[0-9]+d [0-9]+h [0-9]+m$' "$work/out" || fail_showing "$work/out" "no uptime"
  [ "$(tail -n 1 "$work/out")" = "Health     OK" ] || fail_showing "$work/out" "the verdict is not OK"
}

@test "stats: a VM without sensors judges what it has, and lacking sensors is no warning" {
  vm_kernel

  stats_cleanly

  for row in RAM Swap Disk CPU Agents Up; do
    grep -Eq "^$row " "$work/out" || fail_showing "$work/out" "no $row row"
  done
  ! grep -Eq '^(CPU temp|NVMe temp|Fan|Throttled|Battery|Bat health) ' "$work/out" ||
    fail_showing "$work/out" "a row without its sensor"
  # The build machine's own disk may add itself; nothing else may.
  grep -Eq '^Health +(OK|(WARNING|CRITICAL) - Disk [0-9]+% used)$' "$work/out" ||
    fail_showing "$work/out" "the verdict judges more than the disk"
}

@test "stats: the worst state wins the verdict and every row that is not normal is a reason" {
  thinkpad_kernel
  sensor class/hwmon/hwmon7/temp1_input 77850
  sensor class/power_supply/BAT0/energy_full 50000000

  stats_cleanly

  # The build machine's own disk may add itself; nothing else may.
  grep -Eq '^Health +CRITICAL - (Disk [0-9]+% used, )?NVMe temp 77 C, Bat health 73%$' "$work/out" ||
    fail_showing "$work/out" "the verdict is not a critical naming exactly the two rows"
}

@test "stats: a warning alone makes the verdict a warning" {
  thinkpad_kernel
  [ "$(state_of Disk)" = normal ] || skip "the build machine's own disk is not normal"
  sensor class/hwmon/hwmon7/temp1_input 65000

  stats_cleanly
  grep -Eq '^Health +WARNING - NVMe temp 65 C$' "$work/out" || fail_showing "$work/out" "the verdict is not a warning"
}

@test "stats: any missing file only drops its row" {
  each_broken f removed
}

@test "stats: any missing directory only drops its rows" {
  each_broken d removed
}

@test "stats: any file that fails to read only drops its row" {
  each_broken f unreadable
}

@test "stats: any empty file only drops its row" {
  each_broken f emptied
}

@test "stats: any file holding no number only drops its row" {
  each_broken f not_a_number
}

@test "stats: without swap there is no swap row" {
  thinkpad_kernel
  meminfo 9000 0 0

  stats_cleanly
  ! grep -q '^Swap ' "$work/out" || fail_showing "$work/out" "a swap row without swap"
}

@test "stats: hwmon temperatures without labels drop their rows" {
  thinkpad_kernel
  rm "$FACTORY_KERNEL_ROOT"/sys/class/hwmon/hwmon{2,7}/temp*_label

  stats_cleanly
  ! grep -Eq '^(CPU temp|NVMe temp) ' "$work/out" || fail_showing "$work/out" "a temperature without its label"
}

@test "stats: RAM warns from 75% used and is critical from 90%" {
  thinkpad_kernel
  for case in "2501 normal" "2500 warning" "1001 warning" "1000 critical"; do
    read -r available state <<<"$case"
    meminfo "$available" 0 0
    is_state RAM "$state"
  done
}

@test "stats: swap warns from 25% used and is critical from 60%" {
  thinkpad_kernel
  for case in "7501 normal" "7500 warning" "4001 warning" "4000 critical"; do
    read -r free state <<<"$case"
    meminfo 9000 10000 "$free"
    is_state Swap "$state"
  done
}

@test "stats: the agents' memory warns from 75% of the cap and is critical from 90%" {
  thinkpad_kernel
  sensor "$agents/memory.max" 100
  for case in "74 normal" "75 warning" "89 warning" "90 critical"; do
    read -r used state <<<"$case"
    sensor "$agents/memory.current" "$used"
    is_state Agents "$state"
  done
  sensor "$agents/memory.max" max
  is_state Agents normal
}

@test "stats: the load warns above 0.75 per core and is critical above 1.5 per core" {
  thinkpad_kernel
  cores=$(nproc)
  for case in "$((cores * 75)) normal" "$((cores * 75 + 1)) warning" "$((cores * 150)) warning" "$((cores * 150 + 1)) critical"; do
    read -r hundredths state <<<"$case"
    printf '%d.%02d 0.50 0.25 1/100 1234\n' $((hundredths / 100)) $((hundredths % 100)) >"$FACTORY_KERNEL_ROOT/proc/loadavg"
    is_state CPU "$state"
  done
}

@test "stats: the CPU temperature warns from 80 C and is critical from 95 C or 5 C under its crit" {
  thinkpad_kernel
  for case in "79999 100000 normal" "80000 100000 warning" "94999 100000 warning" "95000 100000 critical" \
    "92999 98000 warning" "93000 98000 critical"; do
    read -r temp crit state <<<"$case"
    sensor class/hwmon/hwmon2/temp1_input "$temp"
    sensor class/hwmon/hwmon2/temp1_crit "$crit"
    is_state "CPU temp" "$state"
  done
}

@test "stats: the NVMe temperature warns from 65 C and is critical from the drive's max" {
  thinkpad_kernel
  for case in "64999 normal" "65000 warning" "77849 warning" "77850 critical"; do
    read -r temp state <<<"$case"
    sensor class/hwmon/hwmon7/temp1_input "$temp"
    is_state "NVMe temp" "$state"
  done
  rm "$FACTORY_KERNEL_ROOT/sys/class/hwmon/hwmon7/temp1_max"
  sensor class/hwmon/hwmon7/temp1_input 90000
  is_state "NVMe temp" warning
}

@test "stats: a stopped fan warns from a 60 C CPU and is critical from 80 C; a spinning one never" {
  thinkpad_kernel
  for case in "0 59999 normal" "0 60000 warning" "0 79999 warning" "0 80000 critical" "1 99000 normal"; do
    read -r rpm temp state <<<"$case"
    sensor class/hwmon/hwmon4/fan1_input "$rpm"
    sensor class/hwmon/hwmon2/temp1_input "$temp"
    is_state Fan "$state"
  done
}

# throttled <count>: the heat slowdowns since boot, all on one core.
throttled() { sensor devices/system/cpu/cpu0/thermal_throttle/core_throttle_count "$1"; }

throttle_file() { echo "$HOME/.local/state/factory/throttle-count"; }

@test "stats: the first run shows the slowdowns since boot as normal and keeps the count" {
  thinkpad_kernel
  throttled 8763

  stats_cleanly
  grep -Eq '^Throttled +8763 +times since boot +normal$' "$work/out" || fail_showing "$work/out" "the first run is not a normal total"
  [ "$(cat "$(throttle_file)")" = 8763 ] || fail "the count was not kept"
}

@test "stats: no new slowdown since the last run is normal" {
  thinkpad_kernel
  throttled 8763
  stats_cleanly

  stats_cleanly
  grep -Eq '^Throttled +8763 +times since boot, \+0 +normal$' "$work/out" ||
    fail_showing "$work/out" "an unchanged count is not normal"
}

@test "stats: a large count and rise keep the state in the CPU temp row's column" {
  thinkpad_kernel
  throttled 41144
  stats_cleanly
  throttled 52288

  stats_cleanly
  [ "$(grep -E '^Throttled ' "$work/out" | grep -bo 'warning$' | cut -d: -f1)" = \
    "$(grep -E '^CPU temp ' "$work/out" | grep -bo 'normal$' | cut -d: -f1)" ] ||
    fail_showing "$work/out" "the Throttled state is out of its column"
}

@test "stats: a slowdown since the last run warns, and is critical while the CPU is at 95 C" {
  thinkpad_kernel
  throttled 8751
  stats_cleanly
  throttled 8763

  stats_cleanly
  grep -Eq '^Throttled +8763 +times since boot, \+12 +warning$' "$work/out" ||
    fail_showing "$work/out" "a rise does not warn"
  throttled 8764
  sensor class/hwmon/hwmon2/temp1_input 94999
  is_state Throttled warning
  throttled 8765
  sensor class/hwmon/hwmon2/temp1_input 95000
  is_state Throttled critical
  is_state Throttled normal
}

@test "stats: a slowdown since the last run warns without a CPU temperature" {
  thinkpad_kernel
  rm -r "$FACTORY_KERNEL_ROOT/sys/class/hwmon/hwmon2"
  stats_cleanly
  throttled 2

  is_state Throttled warning
}

@test "stats: a count lower than the last run's is a reboot and a fresh baseline" {
  thinkpad_kernel
  throttled 8763
  stats_cleanly
  throttled 3

  stats_cleanly
  grep -Eq '^Throttled +3 +times since boot +normal$' "$work/out" || fail_showing "$work/out" "a reboot is not a normal baseline"
  throttled 4
  is_state Throttled warning
}

@test "stats: a garbled or unreadable kept count is a fresh baseline" {
  thinkpad_kernel
  throttled 5
  for break in emptied not_a_number unreadable; do
    rm -rf "$(throttle_file)"
    mkdir -p "$(dirname "$(throttle_file)")"
    echo 1 >"$(throttle_file)"
    "$break" "$(throttle_file)"

    stats_cleanly "$break"
    grep -Eq '^Throttled +5 +times since boot +normal$' "$work/out" || fail_showing "$work/out" "$break count is not a baseline"
  done
}

@test "stats: a state directory that cannot be made keeps no count and still runs cleanly" {
  thinkpad_kernel
  throttled 5
  mkdir -p "$HOME/.local/state"
  touch "$HOME/.local/state/factory"

  stats_cleanly
  stats_cleanly
  grep -Eq '^Throttled +5 +times since boot +normal$' "$work/out" || fail_showing "$work/out" "a missing baseline is not normal"
}

@test "stats: a VM without slowdown counters keeps no count" {
  vm_kernel

  stats_cleanly
  [ ! -e "$(throttle_file)" ] || fail "a count was kept without counters"
}

@test "stats: a single heat slowdown reads 1 time" {
  thinkpad_kernel
  sensor devices/system/cpu/cpu1/thermal_throttle/core_throttle_count 1

  stats_cleanly
  grep -Eq '^Throttled +1 +time since boot ' "$work/out" || fail_showing "$work/out" "the count is not 1 time"
}

@test "stats: a discharging battery warns under 60% and is critical under 20%; not charging only warns" {
  thinkpad_kernel
  for case in "Discharging 60 normal" "Discharging 59 warning" "Discharging 20 warning" "Discharging 19 critical" \
    "Not_charging 60 normal" "Not_charging 59 warning" "Not_charging 5 warning" "Charging 5 normal"; do
    read -r status capacity state <<<"$case"
    sensor class/power_supply/BAT0/status "${status/_/ }"
    sensor class/power_supply/BAT0/capacity "$capacity"
    is_state Battery "$state"
  done
}

@test "stats: a core's slowdowns count once, though each of its hyperthreads reports them" {
  thinkpad_kernel
  for cpu in cpu0 cpu1; do
    sensor "devices/system/cpu/$cpu/thermal_throttle/core_throttle_count" 3
    sensor "devices/system/cpu/$cpu/thermal_throttle/package_throttle_count" 2
    sensor "devices/system/cpu/$cpu/topology/physical_package_id" 0
    sensor "devices/system/cpu/$cpu/topology/core_id" 0
  done

  stats_cleanly
  grep -Eq '^Throttled +5 +times' "$work/out" || fail_showing "$work/out" "not 2 package plus 3 core slowdowns"
}

@test "stats: battery health warns under 85% of design and is critical under 60%" {
  thinkpad_kernel
  sensor class/power_supply/BAT0/energy_full_design 100
  for case in "85 normal" "84 warning" "60 warning" "59 critical"; do
    read -r full state <<<"$case"
    sensor class/power_supply/BAT0/energy_full "$full"
    is_state "Bat health" "$state"
  done
}
