# shellcheck shell=bash
sizes="$1" ceilings="$2" status=0

# About 4 bytes per token for English across modern tokenizers, rounded up.
tokens() {
  echo $((($1 + 3) / 4))
}

printf '%-20s %-16s %8s %8s\n' metric subject tokens ceiling
while read -r key subject bytes; do
  size=$(tokens "$bytes")
  ceiling=$(jq -r --arg key "$key" '.[$key] // "none"' "$ceilings")
  verdict=""
  if [ "$ceiling" = none ] || [ "$size" -gt "$ceiling" ]; then
    verdict=" OVER"
    status=1
  fi
  printf '%-20s %-16s %8d %8s%s\n' "$key" "$subject" "$size" "$ceiling" "$verdict"
done <"$sizes"
for key in $(jq -r 'keys | .[]' "$ceilings"); do
  if ! grep -q "^$key " "$sizes"; then
    echo "$key: a ceiling nothing measures" >&2
    status=1
  fi
done
exit "$status"
