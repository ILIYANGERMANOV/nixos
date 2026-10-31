# shellcheck shell=bash disable=SC2154 # set by another fragment: the assembled script is checked whole
# Turning repositories on and off. "On" means enabled - started at boot - and
# running; "off" means neither. The clone and its worktrees are kept either way.

# start <name|git-url> [name]: clone if needed, enable, start. Idempotent.
cmd_start() {
  local target="${1:?usage: factory-ctl start <name|git-url> [name]}" name
  case "$target" in
    *:* | */*)
      name="${2:-$(repo_name_from_url "$target")}"
      check_repo_name "$name"
      clone "$target" "$name"
      ;;
    *)
      name="$target"
      check_repo_name "$name"
      # shellcheck disable=SC2310 # a predicate
      is_cloned "$name" || {
        echo "factory-ctl: $name is not cloned. Find its URL with: factory-ctl resolve $name" >&2
        exit "$exit_not_cloned"
      }
      ;;
  esac
  enable_repo "$name"
  repo_unit start "$name"
  echo "$name: on"
}

# stop [--force] <name>: stop and disable. Refuses while sessions are live or
# worktrees hold local work, unless forced.
cmd_stop() {
  parse_force "$@"
  local name="${args[0]:?usage: factory-ctl stop [--force] <name>}"
  check_repo_name "$name"
  # shellcheck disable=SC2310 # both are predicates
  if [ "$force" -eq 0 ] && is_cloned "$name" && ! check_nothing_at_risk "$name"; then
    refuse "stopping $name ends its sessions"
  fi
  disable_repo "$name"
  repo_unit stop "$name"
  echo "$name: off"
}

# restart [--force] <name>: restart an enabled repository's server, which also
# applies a newly deployed configuration to it.
cmd_restart() {
  parse_force "$@"
  local name="${args[0]:?usage: factory-ctl restart [--force] <name>}"
  check_repo_name "$name"
  # shellcheck disable=SC2310 # a predicate
  is_enabled "$name" || die "$name is off; turn it on with: factory-ctl start $name"
  # shellcheck disable=SC2310 # a predicate
  if [ "$force" -eq 0 ] && ! check_nothing_at_risk "$name"; then
    refuse "restarting $name ends its sessions"
  fi
  repo_unit restart "$name"
  echo "$name: restarted"
}

# resolve <name>: the SSH URLs of every repository named <name> that the bot can
# see, one per line. The skill asks which one when there are several.
cmd_resolve() {
  local name="${1:?usage: factory-ctl resolve <name>}" urls
  check_repo_name "$name"
  urls=$(gh api --paginate /user/repos \
    --jq ".[] | select(.name | ascii_downcase == (\"$name\" | ascii_downcase)) | .ssh_url")
  [ -n "$urls" ] || die "no repository named $name is visible to the bot"
  echo "$urls"
}

# boot [<name> <url>]...: run at login. Clones and enables the declared
# repositories that are missing, then starts every enabled one. A declared
# repository that is already cloned keeps whatever state it has, so a stopped
# one stays stopped. One failure does not stop the rest.
cmd_boot() {
  local status=0 name url
  adopt_existing_clones
  while [ "$#" -ge 2 ]; do
    name="$1" url="$2"
    shift 2
    check_repo_name "$name"
    # shellcheck disable=SC2310 # one failure must not stop the rest
    is_cloned "$name" || { clone "$url" "$name" && enable_repo "$name"; } || status=1
  done
  for name in $(enabled_repos); do
    # shellcheck disable=SC2310 # a predicate
    if is_cloned "$name"; then
      # shellcheck disable=SC2310 # one failure must not stop the rest
      repo_unit start "$name" || status=1
    else
      echo "factory-ctl: $name is enabled but not cloned, skipping" >&2
    fi
  done
  return "$status"
}

# Before the enabled set existed every clone was started at boot. The first boot
# with it keeps that behaviour by enabling every existing clone once.
adopt_existing_clones() {
  [ -f "$state_file" ] && return 0
  mkdir -p "${state_file%/*}"
  cloned_repos >"$state_file"
}

clone() {
  local url="$1" name="$2" dir="$repos_dir/$2"
  if [ -e "$dir" ]; then
    echo "$name: $dir already exists, keeping it."
  else
    mkdir -p "$repos_dir"
    git clone --quiet "$url" "$dir"
  fi
}

# git@github.com:owner/repo.git, https://github.com/owner/repo -> repo
repo_name_from_url() {
  local base="${1##*[/:]}"
  echo "${base%.git}"
}
