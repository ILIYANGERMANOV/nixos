# Freeing disk without losing work or making the repositories slow again.
#
# Reclaimed: worktrees with no local work and no live session (everything in
# them is on GitHub), throwaway caches, /qa run directories untouched for a
# day (their proof is on the PR), result links of builds left in /tmp or
# ~/.cache for two days, and Nix store paths nothing refers to.
# Kept: the Hackage index and cabal store and Nix's evaluation cache, so the
# next build in a repository stays fast, and /qa's login state and scripts,
# so the next QA run needs no login and no rewrite. Each repository's main
# dev shell is rooted by root-shells; any other shell is store garbage once
# nobody is in it, and comes back from the binary caches.

# Where the /qa skill keeps its login state, scripts and runs, per repository.
qa_dir="$HOME/.cache/qa"

# free-disk plan | apply: list what would go with sizes, or delete it.
cmd_free_disk() {
  case "${1:-}" in
    plan) plan_disk ;;
    apply) apply_disk ;;
    *) die "usage: factory-ctl free-disk plan|apply" ;;
  esac
}

# root-shells: roots what `nix develop` needs on each repository's origin/main,
# which a `nix develop` leaves unrooted, so a GC does not cost the next session
# minutes of downloads. Bounded: one shell generation and the locked inputs per
# repository, replaced on every run. One failure does not stop the rest.
# print-dev-env, because `nix develop -c` would run main's shellHook unattended.
cmd_root_shells() {
  local repo status=0
  for repo in $(cloned_repos); do
    root_shell "$repo" || {
      echo "factory-ctl: could not root the dev shell of $repo" >&2
      status=1
    }
  done
  return "$status"
}

# Inputs come first, so a repository without a default shell still keeps them.
root_shell() {
  local repo="$1" dir="$HOME/.gcroots/$1" flake inputs path
  flake="git+file://$repos_dir/$repo?ref=refs/remotes/origin/main"
  git -C "$repos_dir/$repo" fetch --quiet origin main || return 1
  git -C "$repos_dir/$repo" cat-file -e origin/main:flake.nix 2>/dev/null || return 0
  inputs=$(nix flake archive --json "$flake" | jq -r '[.. | .path? // empty] | unique | .[]') || return 1
  rm -rf "$dir/inputs"
  mkdir -p "$dir/inputs"
  for path in $inputs; do
    nix-store --realise --add-root "$dir/inputs/${path##*/}" "$path" >/dev/null || return 1
  done
  nix print-dev-env "$flake" --profile "$dir/default" >/dev/null || return 1
  nix profile wipe-history --profile "$dir/default"
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
  echo "QA runs:"
  while read -r path; do
    printf '  %-8s %s\n' "$(size_of "$path")" "${path#"$qa_dir"/}"
  done < <(qa_runs)
  echo "Stale GC roots (store path size):"
  while read -r path; do
    printf '  %-8s %s\n' "$(size_of "$(readlink -f "$path")")" "$path"
  done < <(own_stale_roots)
  dead=$(nix-store --gc --print-dead 2>/dev/null | xargs -r du -sbc 2>/dev/null | tail -n 1 | cut -f 1) || true
  printf 'Nix store garbage: %s\n' "$(human "${dead:-0}")"
  echo "Free now: $(gb "$(free_bytes)")"
}

apply_disk() {
  local wt path repo before after
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
    rm -rf "$path"
    echo "removed ${path#"$HOME"/}"
  done < <(qa_runs)
  # A run's worktree that had changes outside .gitignore was deleted with its
  # run rather than by worktree remove: drop its registration.
  for repo in $(cloned_repos); do
    git -C "$repos_dir/$repo" worktree prune
  done
  while read -r path; do
    rm -f "$path"
    echo "removed $path"
  done < <(own_stale_roots)
  nix-store --gc >/dev/null 2>&1
  after=$(free_bytes)
  echo "Freed $(gb $((after - before)))"
  echo "Free now: $(gb "$after")"
}

free_bytes() { df -B1 --output=avail / | tail -n 1; }

# Secondary worktrees whose deletion loses nothing.
prunable_worktrees() {
  local repo wt
  for repo in $(cloned_repos); do
    while read -r wt; do
      [ "$wt" != "$repos_dir/$repo" ] || continue
      # A /qa run's worktree is clean while the run is live: qa_runs decides.
      case "$wt" in "$qa_dir"/*) continue ;; esac
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
      "$HOME/.cache/nix" | "$HOME/.cache/cabal" | "$qa_dir") ;;
      # A symlink here is a dev shell's profile or a build's result link, a GC
      # root rather than a cache: stale_roots decides about those.
      *) [ -e "$path" ] && [ ! -L "$path" ] && echo "$path" ;;
    esac
  done
  return 0
}

# /qa's run directories (~/.cache/qa/<owner>/<repo>/runs/<run>) with nothing
# written for a day, so a run in progress keeps its videos. Never auth/ or
# scripts/, which sit beside runs/.
qa_runs() {
  local run
  for run in "$qa_dir"/*/*/runs/*/; do
    run="${run%/}"
    [ -d "$run" ] && [ -z "$(find "$run" -newermt '1 day ago' -print -quit)" ] && echo "$run"
  done
  return 0
}

# The result links of the stale roots this account made, the only ones it may
# delete from the sticky /tmp. Deleting one leaves its registration dangling,
# which the next GC drops.
own_stale_roots() {
  local link
  while read -r link; do
    find "$(readlink "$link")" -maxdepth 0 -user "$(id -u)" 2>/dev/null || true
  done < <(stale_roots "$tmp_dir" "$HOME/.cache")
}

size_of() { human "$(du -sb "$1" 2>/dev/null | cut -f 1)"; }

human() { awk -v b="${1:-0}" 'BEGIN { if (b >= 1e9) printf "%.1fG", b / 1e9; else printf "%.0fM", b / 1e6 }'; }
