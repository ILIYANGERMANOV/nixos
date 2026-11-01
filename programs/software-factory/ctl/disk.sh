# shellcheck shell=bash disable=SC2154,SC2312 # other fragments and the preamble's pipefail: the assembled script is checked whole
# Freeing disk without losing work or making the repositories slow again.
#
# Reclaimed: worktrees with no local work and no live session (everything in
# them is on GitHub), throwaway caches, /qa run directories untouched for a
# day (their proof is on the PR), result links of builds left in /tmp or
# ~/.cache for two days, and Nix store paths nothing refers to.
# Kept: the Hackage index and cabal store and Nix's evaluation cache, so the
# next build in a repository stays fast, and /qa's login state and scripts,
# so the next QA run needs no login and no rewrite. /10x-engineer's worktrees
# stay too: a task waiting for review is clean, pushed and sessionless, and the
# run removes them itself. Each repository's main dev shell is rooted by
# root-shells; any other shell is store garbage once nobody is in it, and comes
# back from the binary caches.

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
    # shellcheck disable=SC2310 # one failure must not stop the rest
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
  local wt path store_path dead garbage
  echo "Worktrees (clean, pushed, no session):"
  # shellcheck disable=SC2312 # a failed listing lists nothing
  while IFS= read -r -d '' wt; do
    plan_row "$wt" "${wt#"$repos_dir"/}"
  done < <(prunable_worktrees)
  echo "Caches:"
  # shellcheck disable=SC2312 # a failed listing lists nothing
  while IFS= read -r -d '' path; do
    plan_row "$path" "${path#"$HOME"/}"
  done < <(caches)
  echo "QA runs:"
  # shellcheck disable=SC2312 # a failed listing lists nothing
  while IFS= read -r -d '' path; do
    plan_row "$path" "${path#"$qa_dir"/}"
  done < <(qa_runs)
  echo "Stale GC roots (store path size):"
  # shellcheck disable=SC2312 # a failed listing lists nothing
  while IFS= read -r -d '' path; do
    store_path=$(readlink -f "$path") || true
    plan_row "$store_path" "$path"
  done < <(own_stale_roots)
  dead=$(nix-store --gc --print-dead 2>/dev/null | xargs -r du -sbc 2>/dev/null | tail -n 1 | cut -f 1) || true
  garbage=$(human "${dead:-0}")
  printf 'Nix store garbage: %s\n' "$garbage"
  # shellcheck disable=SC2312 # a plan is a report: df failing must not end it
  echo "Free now: $(gb "$(free_bytes)")"
}

plan_row() {
  local size
  size=$(size_of "$1")
  printf '  %-8s %s\n' "$size" "$2"
}

apply_disk() {
  local wt path repo before after freed free
  before=$(free_bytes)
  # shellcheck disable=SC2312 # a failed listing lists nothing
  while IFS= read -r -d '' wt; do
    repo="${wt#"$repos_dir"/}"
    repo="${repo%%/*}"
    # Clean and pushed was checked, so --force only covers ignored files such
    # as build output.
    git -C "$repos_dir/$repo" worktree remove --force "$wt"
    echo "removed ${wt#"$repos_dir"/}"
  done < <(prunable_worktrees)
  # shellcheck disable=SC2312 # a failed listing lists nothing
  while IFS= read -r -d '' path; do
    rm -rf "$path"
    echo "removed ${path#"$HOME"/}"
  done < <(
    caches
    qa_runs
  )
  # A run's worktree that had changes outside .gitignore was deleted with its
  # run rather than by worktree remove: drop its registration.
  for repo in $(cloned_repos); do
    git -C "$repos_dir/$repo" worktree prune
  done
  # shellcheck disable=SC2312 # a failed listing lists nothing
  while IFS= read -r -d '' path; do
    rm -f "$path"
    echo "removed $path"
  done < <(own_stale_roots)
  nix-store --gc >/dev/null 2>&1
  after=$(free_bytes)
  freed=$(gb $((after - before)))
  free=$(gb "$after")
  echo "Freed $freed"
  echo "Free now: $free"
}

free_bytes() { df -B1 --output=avail / | tail -n 1; }

# The paths each kind of space may go, NUL-terminated: disk_plan.py decides, and
# a listing that fails lists nothing.
prunable_worktrees() { "$disk_plan" worktrees "$repos_dir" "$session_pattern"; }
caches() { "$disk_plan" caches "$HOME" "$qa_dir"; }
qa_runs() { "$disk_plan" qa-runs "$qa_dir"; }
own_stale_roots() { "$disk_plan" own-stale-roots "$gcroots_auto" "$tmp_dir" "$HOME/.cache"; }

# du still prints a total when it fails on part of the tree.
size_of() {
  local bytes
  bytes=$(du -sb "$1" 2>/dev/null | cut -f 1) || true
  human "$bytes"
}

human() { awk -v b="${1:-0}" 'BEGIN { if (b >= 1e9) printf "%.1fG", b / 1e9; else printf "%.0fM", b / 1e6 }'; }
