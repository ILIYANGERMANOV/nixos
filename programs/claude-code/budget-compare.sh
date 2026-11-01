# shellcheck shell=bash
sizes="$1" ceilings="$2" status=0
printf '%-20s %-16s %8s %8s\n' metric subject bytes ceiling
while read -r key subject bytes; do
  ceiling=$(jq -r --arg key "$key" '.[$key] // "none"' "$ceilings")
  verdict=""
  if [ "$ceiling" = none ] || [ "$bytes" -gt "$ceiling" ]; then
    verdict=" OVER"
    status=1
  fi
  printf '%-20s %-16s %8d %8s%s\n' "$key" "$subject" "$bytes" "$ceiling" "$verdict"
done <"$sizes"
for key in $(jq -r 'keys | .[]' "$ceilings"); do
  if ! grep -q "^$key " "$sizes"; then
    echo "$key: a ceiling nothing measures" >&2
    status=1
  fi
done
exit "$status"
