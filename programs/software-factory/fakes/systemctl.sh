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
  show)
    # show -p MainPID --value <pattern>...: a unit file holds its MainPID, an
    # empty one has none (0).
    shift 4
    for pattern in "$@"; do
      for unit in "$UNITS"/$pattern; do
        [ -e "$unit" ] || continue
        if [ -s "$unit" ]; then cat "$unit"; else echo 0; fi
      done
    done
    ;;
  *) ;;
esac
