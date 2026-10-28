# Freeing disk without losing work or making the repositories slow again.
#
# Reclaimed: worktrees with no local work and no live session (everything in
# them is on GitHub), throwaway caches, result links of builds left in /tmp or
# ~/.cache for two days, and Nix store paths nothing refers to.
# Kept: the Hackage index and cabal store and Nix's evaluation cache, so the
# next build in a repository stays fast. Dev shells are not rooted, so the
# store garbage includes any nobody is in; they come back from the binary
# caches.

# free-disk plan | apply: list what would go with sizes, or delete it.
cmd_free_disk() {
  case "${1:-}" in
    plan) plan_disk ;;
    apply) apply_disk ;;
    *) die "usage: factory-ctl free-disk plan|apply" ;;
  esac
}

plan_disk() {
  local wt path dead
  echo "Worktrees (clean, pushed, no session):"
  while read -r wt; do
    printf '  %-8s %s\n' "$(size_of "$wt")" "${wt#"$repos_dir"/}"
  done < <(prunable_worktrees)
  echo "Caches:"
  while read -r path; do
    printf '  %-8s %s\n' "$(size_of "$path")" "${path#"$HOME"/}"
  done < <(caches)
  echo "Stale GC roots (store path size):"
  while read -r path; do
    printf '  %-8s %s\n' "$(size_of "$(readlink -f "$path")")" "$path"
  done < <(own_stale_roots)
  dead=$(nix-store --gc --print-dead 2>/dev/null | xargs -r du -sbc 2>/dev/null | tail -n 1 | cut -f 1) || true
  printf 'Nix store garbage: %s\n' "$(human "${dead:-0}")"
  awk -v a="$(free_bytes)" 'BEGIN { printf "Free now: %.1f GB\n", a / 1e9 }'
}

apply_disk() {
  local wt path repo before
  before=$(free_bytes)
  while read -r wt; do
    repo="${wt#"$repos_dir"/}"
    repo="${repo%%/*}"
    # Clean and pushed was checked, so --force only covers ignored files such
    # as build output.
    git -C "$repos_dir/$repo" worktree remove --force "$wt"
    echo "removed ${wt#"$repos_dir"/}"
  done < <(prunable_worktrees)
  while read -r path; do
    rm -rf "$path"
    echo "removed ${path#"$HOME"/}"
  done < <(caches)
  while read -r path; do
    rm -f "$path"
    echo "removed $path"
  done < <(own_stale_roots)
  nix-store --gc >/dev/null 2>&1
  awk -v b="$before" -v a="$(free_bytes)" 'BEGIN { printf "Freed %.1f GB\nFree now: %.1f GB\n", (a - b) / 1e9, a / 1e9 }'
}

free_bytes() { df -B1 --output=avail / | tail -n 1; }

# Secondary worktrees whose deletion loses nothing.
prunable_worktrees() {
  local repo wt
  for repo in $(cloned_repos); do
    while read -r wt; do
      [ "$wt" != "$repos_dir/$repo" ] || continue
      [ -z "$(sessions_under "$wt")" ] || continue
      [ -z "$(local_work "$wt")" ] || continue
      echo "$wt"
    done < <(worktrees_of "$repo")
  done
}

caches() {
  local path
  for path in "$HOME"/.cache/* "$HOME/.cache/cabal/logs" "$HOME/.npm/_cacache"; do
    case "$path" in
      "$HOME/.cache/nix" | "$HOME/.cache/cabal") ;;
      *) [ -e "$path" ] && echo "$path" ;;
    esac
  done
  return 0
}

# The stale roots this account made, the only ones it may delete from the
# sticky /tmp.
own_stale_roots() {
  local root
  while read -r root; do
    find "$root" -maxdepth 0 -user "$(id -u)"
  done < <(stale_roots "$tmp_dir" "$HOME/.cache")
}

size_of() { human "$(du -sb "$1" 2>/dev/null | cut -f 1)"; }

human() { awk -v b="${1:-0}" 'BEGIN { if (b >= 1e9) printf "%.1fG", b / 1e9; else printf "%.0fM", b / 1e6 }'; }
