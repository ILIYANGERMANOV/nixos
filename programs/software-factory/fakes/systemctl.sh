# shellcheck shell=bash
echo "systemctl $*" >>"$CALLS"
[ "$1" != --user ] || shift
[ "$1" != --no-block ] || shift
mkdir -p "$UNITS"
case "$1" in
  start | restart) touch "$UNITS/$2" ;;
  stop) rm -f "$UNITS/$2" ;;
  is-active)
    if [ "$2" = --quiet ]; then
      [ "${SSHD_UP:-1}" = 1 ]
      exit
    fi
    if [ -e "$UNITS/$2" ]; then echo active; else
      echo inactive
      exit 3
    fi
    ;;
  *) ;;
esac
