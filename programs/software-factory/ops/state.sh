# The outcome of the last root operation, for `factory-ctl status`. The state
# directory is world-readable and holds nothing secret.
record() {
  local op="$1" state="$2" sha="$3" message="$4"
  echo "$op $state: $message"
  mkdir -p "$state_dir"
  jq -n --arg op "$op" --arg state "$state" --arg sha "$sha" --arg message "$message" \
    --arg at "$(date -u '+%F %H:%M UTC')" \
    '{$op, $state, sha: (if $sha == "" then null else $sha end), $message, $at}' >"$state_dir/last.json.tmp"
  mv "$state_dir/last.json.tmp" "$state_dir/last.json"
}
