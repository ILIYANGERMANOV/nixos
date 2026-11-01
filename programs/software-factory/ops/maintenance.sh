# shellcheck shell=bash disable=SC2154 # set by another fragment: the assembled script is checked whole
# rollback | reboot | gc, as root. Each is started by a unit the agent account
# may start through polkit, so each takes no input: what it does is fixed here.

main() {
  op="${1:?usage: factory-maintenance rollback|reboot|gc}"
  # errtrace carries the trap into the functions below.
  set -o errtrace
  trap 'record "$op" failure "" "Failed; see journalctl -u factory-$op"' ERR
  case "$op" in
    rollback) rollback ;;
    reboot) reboot_box ;;
    gc) gc ;;
    *) exit 1 ;;
  esac
}

# Back to the previous system generation, as the boot default too.
rollback() {
  local generation
  nix-env -p "$profile" --rollback
  "$(readlink -f "$profile")/bin/switch-to-configuration" switch
  # Already switched: a name left blank must not turn this into a failure.
  generation=$(readlink "$profile") || true
  record rollback success "" "Switched to $generation"
}

# Refused within 10 minutes of boot, so a loop of requests cannot keep the box
# rebooting.
reboot_box() {
  local up
  up=$(cut -d . -f 1 "$uptime_file")
  if [ "$up" -lt 600 ]; then
    record reboot failure "" "Refused: booted ${up}s ago, less than 10 minutes"
    exit 1
  fi
  record reboot success "" "Rebooting"
  systemctl reboot
}

# Keeps the current generation of every profile and the one before it, which
# is all a rollback goes back to, unregisters the result links builds left in
# temporary directories, then collects everything unreferenced. Worktree roots
# in ~/.gcroots, profiles and home-manager's roots are never temporary, so
# they stay.
gc() {
  local before after dir link freed
  before=$(df -B1 --output=avail /nix/store | tail -n 1)
  nix-env -p "$profile" --delete-generations +2
  trim_profiles /root /root/.local/state/nix/profiles
  for dir in /nix/var/nix/profiles/per-user/*; do
    trim_profiles "$dir" "$dir"
  done
  for dir in "$homes_dir"/*; do
    trim_profiles "$dir" "$dir/.local/state/nix/profiles"
  done
  # Only the registration in $gcroots_auto goes: root never deletes a path an
  # agent chose. The orphaned link dangles until tmpfiles or its owner drops it.
  # shellcheck disable=SC2046,SC2312 # one directory per home; a failed listing removes nothing
  while IFS= read -r -d '' link; do
    rm -f -- "$link"
  done < <("$disk_plan" stale-roots "$gcroots_auto" "$tmp_dir" $(home_caches))
  nix-store --gc
  after=$(df -B1 --output=avail /nix/store | tail -n 1)
  freed=$(gb $((after - before)))
  record gc success "" "Freed $freed"
}

# trim_profiles <owned-dir> <profiles-dir>: keeps two generations of each profile
# under <profiles-dir>, by its unnumbered name: the numbered *-N-link entries are
# its generations. All of it runs as the owner of <owned-dir>, whose paths it is
# free to point anywhere, so nothing here reaches past that account's own rights.
trim_profiles() {
  local owned="$1" dir="$2" p
  [ -d "$owned" ] || return 0
  # shellcheck disable=SC2310,SC2312 # a failed listing trims nothing
  while IFS= read -r -d '' p; do
    as_owner "$owned" nix-env -p "$p" --delete-generations +2
  done < <(as_owner "$owned" find "$dir" -maxdepth 2 -type l ! -name '*-link' -print0 2>/dev/null || true)
}

# as_owner <path> <command>...: runs the command as the user and group of <path>.
as_owner() {
  local uid gid
  uid=$(stat -c %u "$1")
  gid=$(stat -c %g "$1")
  shift
  "$setpriv" --reuid="$uid" --regid="$gid" --clear-groups -- "$@"
}

# Every user's ~/.cache.
home_caches() {
  find "$homes_dir" -mindepth 2 -maxdepth 2 -name .cache -type d 2>/dev/null || true
}

main "$@"
