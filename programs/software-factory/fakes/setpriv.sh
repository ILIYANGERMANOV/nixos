# shellcheck shell=bash
echo "setpriv $*" >>"$CALLS"
while [ "$1" != -- ]; do
  case "$1" in
    --reuid=*) export ACTING_AS="${1#--reuid=}" ;;
    *) ;;
  esac
  shift
done
shift
exec "$@"
