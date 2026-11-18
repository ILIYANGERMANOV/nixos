# shellcheck shell=bash
echo "systemd-cgtop $*" >>"$CALLS"
cat <<'TABLE'
CGroup                                              Tasks   %CPU   Memory  Input/s Output/s
/user.slice/user-1000.slice                           120   12.0    18.2G        -        -
/user.slice/user-1000.slice/user@1000.service/ghci.slice  4    1.0    11.5G        -        -
TABLE
