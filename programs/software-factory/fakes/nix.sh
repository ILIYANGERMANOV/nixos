# shellcheck shell=bash disable=SC2154 # check.nix sets $work
echo "nix $*" >>"$CALLS"
case "$1 $2" in
  "flake archive")
    cat "$GH/flake-archive.json"
    exit
    ;;
  print-dev-env*broken*) exit 1 ;;
  develop*) touch "$GH/shell-hook-ran" ;;
  *) ;;
esac
[ ! -e "$GH/build-fails" ] && echo "$work/systems/new"
