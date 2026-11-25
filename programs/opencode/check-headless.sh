# shellcheck shell=bash disable=SC2154,SC2312 # default.nix sets the inputs, and a masked failure fails the assertion around it
# checks.opencode-headless: runs opencode-kategory-headless ($kategory)
# offline in a fresh HOME, with nobody there, and asserts:
#
# - `debug config` denies the question tool;
# - the lead's AGENTS.md holds the headless profile's prose;
# - `run --auto` against a scripted model ($scripted_model) runs its shell
#   call, prints its final text and exits 0, with no step waiting for a
#   person. The model sits on loopback, in place of DeepSeek's API.
set -euo pipefail

export HOME=$PWD/home
project=$HOME/project
mkdir -p "$project"
cd "$project"

fail() {
  echo "opencode-headless-check: $*" >&2
  exit 1
}

"$kategory" debug config >config.json
jq -e '.permission.question == "deny"' config.json >/dev/null || fail "the question tool is not denied"
lead=$(jq -r '.instructions[0]' config.json)
grep -qx '# No user is present' "$lead" || fail "the lead's $lead lacks the headless prose"

marker=HEADLESS-MARKER
final_text="HEADLESS-DONE: the scripted run ended"
python3 -I "$scripted_model" "$PWD/port" "echo $marker > marker.txt" "$final_text" &
model=$!
trap 'kill "$model" 2>/dev/null || true' EXIT
for _ in $(seq 100); do
  [ ! -s port ] || break
  sleep 0.1
done
[ -s port ] || fail "the scripted model did not start"

# The built-in deepseek provider, pointed at the scripted model. No models.dev
# fetch: the build has no network, and OpenCode ships a snapshot.
provider=$(jq -cn --arg url "http://127.0.0.1:$(cat port)/v1" '{provider: {deepseek: {options: {baseURL: $url}}}}')
status=0
# </dev/null is load-bearing: when stdin is not a TTY, `run` reads it to EOF
# for a piped message, so an open pipe stalls it after "init" forever.
OPENCODE_CONFIG_CONTENT=$provider DEEPSEEK_API_KEY=dummy OPENCODE_DISABLE_MODELS_FETCH=1 \
  timeout 120 "$kategory" run --auto "run the scripted command" </dev/null >run.out 2>run.err || status=$?
[ "$status" = 0 ] || fail "run exited $status: $(tail -c 2000 run.out run.err)"
[ "$(cat marker.txt 2>/dev/null)" = "$marker" ] || fail "the shell call did not run: $(tail -c 2000 run.out run.err)"
grep -qF "$final_text" run.out || fail "run did not print the final text: $(cat run.out)"

echo "opencode-headless-check: all good"
