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
  up=$(cut -d . -f 1 /proc/uptime)
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
  local before after p link freed
  before=$(df -B1 --output=avail /nix/store | tail -n 1)
  for p in "$profile" $(profiles); do
    nix-env -p "$p" --delete-generations +2
  done
  # Only the registration in $gcroots_auto goes: root never deletes a path an
  # agent chose. The orphaned link dangles until tmpfiles or its owner drops it.
  # shellcheck disable=SC2046,SC2312 # one directory per home; a failed listing removes nothing
  while read -r link; do
    rm -f -- "$link"
  done < <(stale_roots "$tmp_dir" $(home_caches))
  nix-store --gc
  after=$(df -B1 --output=avail /nix/store | tail -n 1)
  freed=$(gb $((after - before)))
  record gc success "" "Freed $freed"
}

# Every user's profiles, by their unnumbered name: the numbered *-N-link
# entries are their generations.
profiles() {
  find /nix/var/nix/profiles/per-user /root/.local/state/nix/profiles "$homes_dir"/*/.local/state/nix/profiles \
    -maxdepth 2 -type l ! -name '*-link' 2>/dev/null || true
}

# Every user's ~/.cache.
home_caches() {
  find "$homes_dir" -mindepth 2 -maxdepth 2 -name .cache -type d 2>/dev/null || true
}

main "$@"
