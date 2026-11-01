# shellcheck shell=bash disable=SC2154 # set by another fragment: the assembled script is checked whole
# shellcheck disable=SC2312 # a failed df reads as nothing, which fails `read`
read -r avail size < <(df -B1 --output=avail,size / | tail -n 1)
if [ $((avail * 100)) -lt $((size * gc_below_free_percent)) ]; then
  systemctl start --no-block factory-gc.service
fi
