# shellcheck shell=bash disable=SC2034,SC2154,SC2312 # other fragments and the preamble's pipefail: the assembled script is checked whole
# The rest of factory-ctl's shared state: the enabled set, live sessions and
# local work. Sourced into one script after paths.sh, so these are plain
# functions over $HOME.

state_file="${XDG_STATE_HOME:-$HOME/.local/state}/factory/enabled"

# Exit codes the admin skills branch on.
readonly exit_refused=2    # would lose work or end sessions; rerun with --force
readonly exit_not_cloned=3 # a bare name with no clone; needs a URL

# repo_unit <verb> <repo>: runs a systemctl verb on the repository's server.
repo_unit() { systemctl --user "$1" "claude-rc@$2.service"; }

cloned_repos() {
  local dir
  for dir in "$repos_dir"/*/; do
    [ -d "$dir.git" ] && basename "$dir"
  done
  return 0
}

# The enabled set: one repository name per line. It is what boot starts, so a
# stopped repository stays stopped across reboots.
enabled_repos() {
  [ -f "$state_file" ] && cat "$state_file"
  return 0
}

is_enabled() { enabled_repos | grep -qxF "$1"; }

enable_repo() {
  mkdir -p "${state_file%/*}"
  {
    enabled_repos
    echo "$1"
  } | sort -u >"$state_file.tmp"
  mv "$state_file.tmp" "$state_file"
}

disable_repo() {
  mkdir -p "${state_file%/*}"
  # shellcheck disable=SC2310 # the || is for grep, which fails on the last name
  enabled_repos | grep -vxF "$1" >"$state_file.tmp" || true
  mv "$state_file.tmp" "$state_file"
}

# A session is a `claude --print --sdk-url` process; its working directory is
# the repository or one of its worktrees.
session_pattern='--sdk-url'

# Live sessions as "pid<TAB>cwd".
sessions() {
  local pid cwd
  for pid in $(pgrep -u "$EUID" -f -- "$session_pattern"); do
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || continue
    printf '%s\t%s\n' "$pid" "$cwd"
  done
  return 0
}

# Sessions whose working directory is $1 or below it.
sessions_under() {
  sessions | awk -F '\t' -v dir="$1" '$2 == dir || index($2, dir "/") == 1'
}

worktrees_of() {
  git -C "$repos_dir/$1" worktree list --porcelain | sed -n 's/^worktree //p'
}

# The checkout holding $1, a path in a repository: its longest worktree, since
# git's own answer walks past a worktree that lost its .git to the checkout above.
# With none, $1 itself: its work reads as unknown.
checkout_of() {
  local repo="${1#"$repos_dir"/}"
  # shellcheck disable=SC2310,SC2312 # awk answers even when the listing fails
  worktrees_of "${repo%%/*}" | awk -v dir="$1" '
    (dir == $0 || index(dir, $0 "/") == 1) && length($0) > length(longest) { longest = $0 }
    END { print (longest == "" ? dir : longest) }
  ' || true
}

# What would be lost if the worktree were deleted, one phrase per line.
local_work() { "$disk_plan" local-work "$1"; }

# Prints what stopping repository $1 would cost and fails if it costs anything:
# live sessions, or worktrees with local work.
check_nothing_at_risk() {
  local repo="$1" count wt work label at_risk=0
  count=$(sessions_under "$repos_dir/$repo" | wc -l)
  if [ "$count" -gt 0 ]; then
    echo "$repo: $count live session(s)"
    at_risk=1
  fi
  # shellcheck disable=SC2312 # a failed listing has always read as no worktrees
  while read -r wt; do
    work=$(local_work "$wt" | paste -sd ',' | sed 's/,/, /g')
    if [ -n "$work" ]; then
      label=$(worktree_label "$repo" "$wt")
      echo "$repo: $label: $work"
      at_risk=1
    fi
  done < <(worktrees_of "$repo")
  return "$at_risk"
}

worktree_label() {
  case "$2" in
    "$repos_dir/$1") echo "main checkout" ;;
    *) echo "${2#"$repos_dir/$1"/}" ;;
  esac
}

# Shared by commands that take --force: sets $force and leaves the remaining
# arguments in $args.
parse_force() {
  force=0
  args=()
  local arg
  for arg in "$@"; do
    case "$arg" in
      --force) force=1 ;;
      *) args+=("$arg") ;;
    esac
  done
}

refuse() {
  echo "Refused: $1. Rerun with --force to go ahead." >&2
  exit "$exit_refused"
}
