# shellcheck shell=bash disable=SC2154,SC2310,SC2312 # check.nix sets the inputs, run_tool never fails, and a masked failure fails the assertion around it
# checks.opencode: runs opencode-kategory ($kategory) offline in a fresh HOME
# and asserts on what OpenCode itself reports - `debug config`, `debug skill`,
# `debug agent`, a tool run as one agent, and the commands `serve` lists:
#
# - every role ($tiers) is a subagent, on its tier's model or its spawner's,
#   and a project's opencode.json sets the lead's;
# - every skill ($skills) is there and is a command, and none of the user's
#   ~/.claude, ~/.agents or ~/.config/opencode is read;
# - subagent_depth is set, and every instructions path in the store exists;
# - a role that may only read ($read_only_role) cannot run a shell or edit,
#   and a skill that bars the model from it runs only as its command;
# - the plugin loads from the store: a shell gets the user's XDG dirs back,
#   keeps the moved state dir, and finds state, ctx and qa-node;
# - its hooks reach the kernel and the guards: a lead may not edit or patch
#   before its run exists, and a session's bash history and model calls reach
#   the wait and context guards;
# - it remembers the background children running, a rewrite replaces the
#   very args object OpenCode runs the call with, and queued context reaches
#   the next system prompt once;
# - a failing adapter lets the call go on, with a note saying so;
# - no config dir OpenCode scans is writable, so it npm-installs nowhere.
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

# The read-only role in the project's config dir, which is then made
# read-only: OpenCode installs its plugin SDK into a writable config dir, and
# offline that waits about a minute.
project_config=$project/.opencode
mkdir -p "$project_config/agents"
cp "$read_only_role" "$project_config/agents/read-only.md"
chmod -R a-w "$project_config"

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
missing=$(jq -c --argjson want "$skills" '$want - map(.name)' skills.json)
[ "$missing" = "[]" ] || fail "skills missing: $missing"
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

# A project's own opencode.json picks the lead's model over the harness's.
own_model=$HOME/own-model
mkdir -p "$own_model"
echo '{"model": "deepseek/deepseek-flash"}' >"$own_model/opencode.json"
(cd "$own_model" && "$kategory" debug config) >own-model.json
[ "$(jq -r .model own-model.json)" = deepseek/deepseek-flash ] ||
  fail "a project's opencode.json does not set the lead's model"

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
[ -f "$HOME/.opencode-kategory/state/state/kernel-v2.db" ] || fail "state did not use the moved state dir"
[ ! -e "$HOME/.local/state" ] || fail "something wrote the user's state dir"

# The plugin's hooks reach the kernel through the adapter. No hook fires
# offline: `debug agent --tool` skips them, and a prompt needs a model. So the
# plugin is imported by OpenCode's own runtime (BUN_BE_BUN makes its binary
# bun), under the wrapper's env, and its hooks called as OpenCode calls them.
# A failing adapter would let every call go.
cat >hooks.mjs <<'EOF'
const [plugin, directory] = process.argv.slice(2);
const { Kategory } = await import(plugin);
const hooks = await Kategory({ directory });
const lead = "ses_lead";
const child = "ses_child";
let calls = 0;
const created = (info) =>
  hooks.event({ event: { type: "session.created", properties: { info } } });
const modelCall = (id, input) =>
  hooks.event({
    event: {
      type: "message.updated",
      properties: {
        info: {
          id,
          sessionID: lead,
          role: "assistant",
          tokens: { input, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
        },
      },
    },
  });
// A call's error, or "allowed".
const before = async (sessionID, tool, args) => {
  try {
    await hooks["tool.execute.before"]({ tool, sessionID, callID: `call_${++calls}` }, { args });
    return "allowed";
  } catch (error) {
    return error.message;
  }
};
// A tool's output once its after-hooks ran.
const after = async (sessionID, tool, args) => {
  const output = { title: "", output: "ran", metadata: {} };
  await hooks["tool.execute.after"]({ tool, sessionID, callID: `call_${++calls}`, args }, output);
  return output.output;
};
const status = { command: "gh run view 1", description: "CI status" };

await created({ id: lead });
await created({ id: child, parentID: lead, agent: "implementer" });
await hooks["command.execute.before"]({ command: "engineer", sessionID: lead, arguments: "" }, { parts: [] });
const said = {
  edit: await before(lead, "edit", { filePath: `${directory}/a`, oldString: "a", newString: "b" }),
  patch: await before(lead, "apply_patch", { patchText: "*** Begin Patch\n*** Add File: a\n+b\n*** End Patch" }),
  status: await before(child, "bash", status),
  statusAgain: await before(child, "bash", status),
};
await modelCall("msg_1", 305000);
said.crossed = await after(lead, "glob", { pattern: "*" });
await modelCall("msg_2", 306000);
said.past = await after(lead, "glob", { pattern: "*" });
console.log(JSON.stringify(said));
EOF
BUN_BE_BUN=1 "$kategory" hooks.mjs "$plugin" "$project" >hooks.out 2>&1 || fail "the plugin did not run: $(cat hooks.out)"
said() {
  jq -r --arg key "$1" '.[$key]' hooks.out
}
# A lead that typed a flow's command may not edit before its run exists, by
# edit or by apply_patch, the edit of gpt- models.
[[ "$(said edit)" == *"this lead has no run"* ]] || fail "a lead edited before its run: $(cat hooks.out)"
[[ "$(said patch)" == *"this lead has no run"* ]] || fail "a lead patched before its run: $(cat hooks.out)"
# The session's bash history reaches the wait guard: a subagent reads CI once.
[ "$(said status)" = allowed ] || fail "a subagent's first CI read was denied: $(cat hooks.out)"
[[ "$(said statusAgain)" == *"a subagent never waits on CI"* ]] ||
  fail "a subagent read CI twice: $(cat hooks.out)"
# The session's model calls reach the context guard: it speaks as the context
# crosses 300k, not again while it stays past.
[[ "$(said crossed)" == *"Context 305k"* ]] || fail "crossing 300k told the lead nothing: $(cat hooks.out)"
[ "$(said past)" = ran ] || fail "the lead was told again past 300k: $(cat hooks.out)"

# The rest of the plugin's memory, read through a stub adapter: it answers each
# envelope with the envelope itself, and rewrites every read to read b.
stub=$PWD/stub-adapter
{
  echo "#!$BASH"
  cat <<'EOF'
envelope=$(cat)
case $(jq -r '.hook + ":" + (.tool // "")' <<<"$envelope") in
  before:read) echo '{"args": {"filePath": "b"}}' ;;
  *) jq -c '{context: tojson}' <<<"$envelope" ;;
esac
EOF
} >"$stub"
chmod +x "$stub"
sed "s|^const adapter = .*|const adapter = \"$stub\";|" "$plugin" >stub-plugin.mjs
grep -q "\"$stub\"" stub-plugin.mjs || fail "the stub did not replace the plugin's adapter"
cat >memory.mjs <<'EOF'
const [plugin, directory] = process.argv.slice(2);
const { Kategory } = await import(plugin);
const hooks = await Kategory({ directory });
const lead = "ses_lead";
const child = "ses_child";
const created = (info) =>
  hooks.event({ event: { type: "session.created", properties: { info } } });
// The envelope a task's after-hook sent: the stub's answer ends its output.
const sent = async (metadata) => {
  const output = { title: "", output: "ran", metadata };
  await hooks["tool.execute.after"]({ tool: "task", sessionID: lead, callID: "call", args: {} }, output);
  return JSON.parse(output.output.split("\n\n").at(-1));
};

await created({ id: lead });
await created({ id: child, parentID: lead, agent: "implementer" });
const started = await sent({ background: true, sessionId: child });
await hooks.event({ event: { type: "session.idle", properties: { sessionID: child } } });
const ended = await sent({});
// OpenCode runs the call with the args object it passed the hook.
const args = { filePath: "a", limit: 10 };
await hooks["tool.execute.before"]({ tool: "read", sessionID: lead, callID: "read" }, { args });
// The child's idle queued its context for its next system prompt, once.
const transform = async () => {
  const output = { system: [] };
  await hooks["experimental.chat.system.transform"]({ sessionID: child }, output);
  return output.system.map((note) => JSON.parse(note).hook);
};
const prompts = [await transform(), await transform()];
console.log(JSON.stringify({ started: started.running, ended: ended.running, args, prompts }));
EOF
BUN_BE_BUN=1 "$kategory" memory.mjs "$PWD/stub-plugin.mjs" "$project" >memory.out 2>&1 ||
  fail "the stubbed plugin did not run: $(cat memory.out)"
# A background child runs until it goes idle, and a rewrite replaces the args.
# A background child runs until it goes idle, a rewrite replaces the args, and
# a session's queued context reaches its next system prompt only.
jq -e '. == {started: ["ses_child"], ended: [], args: {filePath: "b"}, prompts: [["idle"], []]}' memory.out >/dev/null ||
  fail "the plugin forgot a running child, kept args the hooks dropped or lost queued context: $(cat memory.out)"

# An adapter that fails lets the call go on, with a note saying so.
broken=$PWD/broken-adapter
printf '#!%s\necho boom >&2\nexit 1\n' "$BASH" >"$broken"
chmod +x "$broken"
sed "s|^const adapter = .*|const adapter = \"$broken\";|" "$plugin" >broken-plugin.mjs
grep -q "\"$broken\"" broken-plugin.mjs || fail "the broken stub did not replace the plugin's adapter"
cat >broken.mjs <<'EOF'
const [plugin, directory] = process.argv.slice(2);
const { Kategory } = await import(plugin);
const hooks = await Kategory({ directory });
const call = { tool: "bash", sessionID: "ses_lead", callID: "call" };
const args = { command: "ls", description: "list" };
await hooks["tool.execute.before"](call, { args });
const output = { title: "", output: "ran", metadata: {} };
await hooks["tool.execute.after"]({ ...call, args }, output);
console.log(output.output);
EOF
BUN_BE_BUN=1 "$kategory" broken.mjs "$PWD/broken-plugin.mjs" "$project" >broken.out 2>&1 ||
  fail "a failing adapter stopped the call: $(cat broken.out)"
[[ "$(cat broken.out)" == *"agent-hook-opencode failed, so no hook judged this: boom"* ]] ||
  fail "a failing adapter left no note: $(cat broken.out)"

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
missing=$(jq -c --argjson want "$skills" '$want - map(select(.source == "skill") | .name)' commands.json)
[ "$missing" = "[]" ] || fail "skills with no command: $missing"

# OpenCode writes a .gitignore into each config dir it can write, then runs
# npm install there. So none in HOME means no launch above waited on npm.
written=$(find "$HOME" -name .gitignore)
[ -z "$written" ] || fail "OpenCode wrote a config dir, so it npm-installs there: $written"

echo "opencode-check: all good"
