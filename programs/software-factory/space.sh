# Disk space helpers shared by factory-ctl and factory-maintenance.

# Result symlinks a `nix build` left behind in a temporary directory. Nix
# registers each as an indirect GC root in $gcroots_auto, so a forgotten one
# pins its whole closure until it is deleted.
#
# stale_roots <dir>...: the entries of $gcroots_auto whose result link lies
# under one of these directories and has not changed for two days. Skipped:
# a link whose parent directory resolves elsewhere, since the path is the
# agent's to choose, and a `nix develop --profile` generation (<name>-N-link),
# whose mtime is when the profile was made, not when it was last used.
stale_roots() {
  local link target dir
  for link in "$gcroots_auto"/*; do
    target=$(readlink "$link") || continue
    case "${target##*/}" in *-[0-9]*-link) continue ;; esac
    [ "$(readlink -f "${target%/*}")" = "${target%/*}" ] || continue
    for dir in "$@"; do
      case "$target" in
        "$dir"/*)
          if [ -n "$(find "$target" -maxdepth 0 -type l -mmin +2880 2>/dev/null)" ]; then
            echo "$link"
          fi
          ;;
      esac
    done
  done
}

# gb <bytes>: the amount in GB with one decimal.
gb() { printf '%.1f GB' "$(jq -n "$1 / 1e9")"; }
