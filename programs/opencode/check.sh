# shellcheck shell=bash disable=SC2154,SC2310,SC2312 # check.nix sets the inputs, run_tool never fails, and a masked failure fails the assertion around it
# checks.opencode: runs opencode-kategory ($kategory) offline in a fresh HOME
# and asserts on what OpenCode itself reports - `debug config`, `debug skill`,
# `debug agent`, a tool run as one agent, and the commands `serve` lists:
#
# - every role ($tiers) is a subagent, on its tier's model or its spawner's;
# - every skill ($skills) is there and is a command, and none of the user's
#   ~/.claude, ~/.agents or ~/.config/opencode is read;
# - subagent_depth is set, and every instructions path in the store exists;
# - a role that may only read ($read_only_role) cannot run a shell or edit,
#   and a skill that bars the model from it runs only as its command;
# - the plugin loads from the store: a shell gets the user's XDG dirs back,
#   keeps the moved state dir, and finds state, ctx and qa-node.
set -euo pipefail

export HOME=$PWD/home
project=$HOME/project
mkdir -p "$project"
cd "$project"

fail() {
  echo "opencode-check: $*" >&2
  exit 1
}

# What the user has and opencode-kategory must not read.
for dir in .claude/skills/leak-claude .agents/skills/leak-agents; do
  mkdir -p "$HOME/$dir"
  printf -- '---\nname: %s\ndescription: must not load\n---\n' "${dir##*/}" >"$HOME/$dir/SKILL.md"
done
mkdir -p "$HOME/.config/opencode/agents"
printf -- '---\ndescription: must not load\nmode: subagent\n---\n' >"$HOME/.config/opencode/agents/leak.md"

# The read-only role in OpenCode's own config dir under the moved
# XDG_CONFIG_HOME, which is then made read-only: OpenCode installs its plugin
# SDK into a writable config dir, and offline that waits about a minute.
own_config=$HOME/.opencode-kategory/config/opencode
mkdir -p "$own_config/agents"
cp "$read_only_role" "$own_config/agents/read-only.md"
chmod -R a-w "$own_config"

# One dir the user set and two left to their defaults.
export XDG_CONFIG_HOME=$HOME/user-config
unset XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME

"$kategory" debug config >config.json
jq -e '.subagent_depth >= 3' config.json >/dev/null || fail "subagent_depth is not set"
jq -e '.instructions | map(select(startswith("/") | not)) == ["CLAUDE.md"]' config.json >/dev/null ||
  fail "instructions do not name the project's CLAUDE.md"
jq -r '.instructions[] | select(startswith("/"))' config.json >absolute
[ -s absolute ] || fail "instructions name no file in the store"
while read -r file; do
  [ -f "$file" ] || fail "instructions name $file, which does not exist"
done <absolute

"$kategory" debug skill >skills.json
jq -e --argjson want "$skills" '$want - map(.name) == []' skills.json >/dev/null ||
  fail "skills missing: $(jq -c --argjson want "$skills" '$want - map(.name)' skills.json)"
jq -e 'map(.name) | index("leak-claude") == null and index("leak-agents") == null' skills.json >/dev/null ||
  fail "a skill from ~/.claude or ~/.agents loaded"

# Each role as OpenCode resolved it.
model_of_tier() {
  case $1 in
    small | medium) echo deepseek/deepseek-flash ;;
    large) echo deepseek/deepseek-v4-pro ;;
    null) echo inherited ;;
    *) fail "unknown tier $1" ;;
  esac
}
for role in $(jq -r 'keys[]' <<<"$tiers"); do
  "$kategory" debug agent "$role" >role.json
  jq -e '.mode == "subagent"' role.json >/dev/null || fail "$role is not a subagent"
  want=$(model_of_tier "$(jq -r --arg role "$role" '.[$role]' <<<"$tiers")")
  got=$(jq -r '.model // empty | "\(.providerID)/\(.modelID)"' role.json)
  [ "${got:-inherited}" = "$want" ] || fail "$role runs on ${got:-inherited}, not $want"
done
"$kategory" debug agent leak >/dev/null 2>&1 && fail "the agent from ~/.config/opencode loaded"
[ "$(jq -r .model config.json)" = deepseek/deepseek-v4-pro ] || fail "the lead is not on deepseek-v4-pro"

# A tool run as an agent prints the result as JSON, or a line saying why not.
run_tool() {
  "$kategory" debug agent "$1" --tool "$2" --params "$3" 2>&1 || true
}
for tool in bash edit write task; do
  [[ "$(run_tool read-only "$tool" '{}')" == *"Tool $tool is disabled"* ]] ||
    fail "the read-only role may use $tool"
done
[[ "$(run_tool reviewer edit '{}')" == *"Tool edit is disabled"* ]] || fail "the reviewer may edit"

# chief sets disable-model-invocation: only its command may run it.
[[ "$(run_tool engineer skill '{"name": "chief"}')" == *"prevents you from using this specific tool call"* ]] ||
  fail "the model may invoke chief"
run_tool engineer skill '{"name": "engineer"}' | jq -e '.result.title == "Loaded skill: engineer"' >/dev/null ||
  fail "the engineer role cannot load the engineer skill"

# What a shell sees, and whether `state` writes under the moved state dir.
# shellcheck disable=SC2016 # expanded by the shell OpenCode runs
probe='printf "%s\n" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"
for program in state ctx qa-node; do command -v "$program" >/dev/null && echo "$program"; done
state dump probe >/dev/null 2>&1 || true'
run_tool implementer bash "$(jq -n --arg command "$probe" '{description: "probe", command: $command}')" >shell.json
jq -j .result.output shell.json >shell.out || fail "the shell did not run: $(cat shell.json)"
printf '%s\n' "$HOME/user-config" "$HOME/.local/share" "$HOME/.cache" "$HOME/.opencode-kategory/state" \
  state ctx qa-node >want.out
diff want.out shell.out || fail "a shell sees the XDG dirs or PATH above"
[ -f "$HOME/.opencode-kategory/state/state/kernel.db" ] || fail "state did not use the moved state dir"
[ ! -e "$HOME/.local/state" ] || fail "something wrote the user's state dir"

# Every skill is a command too: `serve` lists them over HTTP.
"$kategory" serve --port 0 >serve.log 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT
for _ in $(seq 600); do
  url=$(sed -n 's|^opencode server listening on \(http://[^ ]*\)$|\1|p' serve.log)
  [ -z "$url" ] || break
  sleep 0.1
done
[ -n "$url" ] || fail "serve did not start: $(cat serve.log)"
curl -sf "$url/command" >commands.json
jq -e --argjson want "$skills" '$want - map(select(.source == "skill") | .name) == []' commands.json >/dev/null ||
  fail "skills with no command: $(jq -c --argjson want "$skills" '$want - map(select(.source == "skill") | .name)' commands.json)"

echo "opencode-check: all good"
