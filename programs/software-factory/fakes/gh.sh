# shellcheck shell=bash
echo "gh $*" >>"$CALLS"
case "$1 $2" in
  "api --paginate") jq -r "$5" "$GH/user-repos.json" ;;
  "workflow run") touch "$GH/dispatched" ;;
  "run list") if [ -e "$GH/dispatched" ]; then echo 42; fi ;;
  "run watch") [ ! -e "$GH/run-fails" ] ;;
  "run view") echo "CI has not passed" ;;
  *) ;;
esac
