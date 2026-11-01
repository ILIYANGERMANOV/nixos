# shellcheck shell=bash disable=SC2154 # set by another fragment: the assembled script is checked whole
main() {
  local name="${1:?usage: factory-rc <repo>}"
  check_repo_name "$name"
  # shellcheck disable=SC2310 # a predicate
  is_cloned "$name" || die "$repos_dir/$name is not a git repository"
  serve "$repos_dir/$name" "$name" "${remote_control_args[@]}"
}
