# shellcheck shell=bash
echo "systemctl $*" >>"$CALLS"
[ "$1" != --user ] || shift
[ "$1" != --no-block ] || shift
mkdir -p "$UNITS"

# Sets matches to the unit files matching glob $1. systemd matches with
# FNM_NOESCAPE, so a `\` in a name like `\x2d` is literal, not an escape as in
# a bash glob.
matching() {
  matches=()
  local unit pattern=${1//\\/\\\\}
  for unit in "$UNITS"/*; do
    [ -e "$unit" ] || continue
    unit=${unit##*/}
    # shellcheck disable=SC2053 # a glob on purpose
    [[ $unit != $pattern ]] || matches+=("$unit")
  done
}

case "$1" in
  start | restart) touch "$UNITS/$2" ;;
  stop)
    shift
    for unit in "$@"; do rm -f "$UNITS/$unit"; done
    ;;
  list-units)
    # list-units --plain --no-legend <pattern>...: the active units, one row each.
    shift 3
    for pattern in "$@"; do
      matching "$pattern"
      for unit in "${matches[@]}"; do
        echo "$unit loaded active running Fake unit"
      done
    done
    ;;
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
      matching "$pattern"
      for unit in "${matches[@]}"; do
        if [ -s "$UNITS/$unit" ]; then cat "$UNITS/$unit"; else echo 0; fi
      done
    done
    ;;
  *) ;;
esac
