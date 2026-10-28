# Result symlinks a `nix build` left behind in a temporary directory. Nix
# registers each as an indirect GC root in $gcroots_auto, so a forgotten one
# pins its whole closure until it is deleted. Shared by factory-ctl and
# factory-maintenance.

# stale_roots <dir>...: the indirect GC roots under these directories that
# have not changed for two days.
stale_roots() {
  local link target dir
  for link in "$gcroots_auto"/*; do
    target=$(readlink "$link") || continue
    for dir in "$@"; do
      case "$target" in
        "$dir"/*) find "$target" -maxdepth 0 -type l -mmin +2880 2>/dev/null || true ;;
      esac
    done
  done
}
