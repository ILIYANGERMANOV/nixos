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
  nix-env -p "$profile" --rollback
  "$(readlink -f "$profile")/bin/switch-to-configuration" switch
  record rollback success "" "Switched to $(readlink "$profile")"
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
# is all a rollback goes back to, drops the result links builds left in
# temporary directories, then collects everything unreferenced. Worktree roots
# in ~/.gcroots, profiles and home-manager's roots are never temporary, so
# they stay.
gc() {
  local before after p
  before=$(df -B1 --output=avail /nix/store | tail -n 1)
  for p in "$profile" $(profiles); do
    nix-env -p "$p" --delete-generations +2
  done
  # shellcheck disable=SC2046 # one directory per home
  stale_roots "$tmp_dir" $(home_caches) | xargs -r rm -f --
  nix-store --gc
  after=$(df -B1 --output=avail /nix/store | tail -n 1)
  record gc success "" "Freed $(printf '%.1f' "$(jq -n "($after - $before) / 1e9")") GB"
}

# Every user's profiles, by their unnumbered name: the numbered *-N-link
# entries are their generations.
profiles() {
  find /nix/var/nix/profiles/per-user /root/.local/state/nix/profiles /home/*/.local/state/nix/profiles \
    -maxdepth 2 -type l ! -name '*-link' 2>/dev/null || true
}

# Every user's ~/.cache.
home_caches() {
  find "$homes_dir" -mindepth 2 -maxdepth 2 -name .cache -type d 2>/dev/null || true
}

main "$@"
