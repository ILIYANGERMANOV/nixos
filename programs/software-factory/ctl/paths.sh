# shellcheck shell=bash
# Where things live, and the repository-name rule. Shared by factory-ctl and
# the Remote Control launchers.

repos_dir="$HOME/repos"

die() {
  echo "${0##*/}: $*" >&2
  exit 1
}

# A repository name becomes a directory and a systemd instance name, so it is
# held to what is safe as both.
check_repo_name() {
  case "$1" in
    "" | .* | *[!A-Za-z0-9._-]*)
      die "invalid repository name '$1' (expected [A-Za-z0-9._-], not starting with '.')"
      ;;
    *) ;;
  esac
}

is_cloned() { [ -d "$repos_dir/$1/.git" ]; }
