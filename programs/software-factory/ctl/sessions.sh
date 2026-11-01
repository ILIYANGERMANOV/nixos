# shellcheck shell=bash disable=SC2154,SC2312 # other fragments and the preamble's pipefail: the assembled script is checked whole
# Ending sessions while their Remote Control servers keep running. Only
# sessions under ~/repos are touched, so the admin agent - which works in
# ~/admin - never ends its own.

# terminate [--force] [name]: end the sessions of one repository, or of all.
# Refuses when a session's worktree holds local work, which suggests the agent
# is mid-task, unless forced. The worktrees themselves are kept.
cmd_terminate() {
  parse_force "$@"
  local repos=("${args[@]}") repo live cwd checkout work count at_risk=0
  # shellcheck disable=SC2312 # cloned_repos cannot fail
  [ "${#repos[@]}" -gt 0 ] || mapfile -t repos < <(cloned_repos)
  for repo in "${repos[@]}"; do
    check_repo_name "$repo"
    # shellcheck disable=SC2310 # a predicate
    is_cloned "$repo" || die "$repo is not cloned"
  done

  live=$(for repo in "${repos[@]}"; do sessions_under "$repos_dir/$repo"; done)
  if [ -z "$live" ]; then
    echo "No live sessions."
    return 0
  fi

  while IFS=$'\t' read -r _ cwd; do
    checkout=$(checkout_of "$cwd")
    work=$(local_work "$checkout" | paste -sd ',' | sed 's/,/, /g')
    if [ -n "$work" ]; then
      echo "${cwd#"$repos_dir"/}: $work"
      at_risk=1
    fi
  done <<<"$live"
  if [ "$force" -eq 0 ] && [ "$at_risk" -eq 1 ]; then
    refuse "these sessions have local work"
  fi

  # shellcheck disable=SC2046,SC2312 # one pid per word, and cut cannot fail here
  kill -TERM $(cut -f 1 <<<"$live")
  count=$(wc -l <<<"$live")
  echo "Ended $count session(s). Their servers keep running."
}
