# shellcheck shell=bash disable=SC2154 # check.nix sets $work
echo "nix-env $*" >>"$CALLS"
[ -n "${ACTING_AS:-}" ] || : >"$2.lock"
case "$3" in
  --set) ln -sfn "$4" "$2" ;;
  --rollback) ln -sfn "$work/systems/old" "$2" ;;
  *) ;;
esac
