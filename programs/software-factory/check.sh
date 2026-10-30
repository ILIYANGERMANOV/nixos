# Scenarios for checks.software-factory, sourced by check.nix with every
# program and double on PATH and $work, $repoArgs, $adminArgs and
# $adminSettings set.

rm -rf "$work"
mkdir -p "$work"
export HOME="$work/home" CALLS="$work/calls" UNITS="$work/units" GH="$work/gh"
export GIT_AUTHOR_NAME=check GIT_AUTHOR_EMAIL=check@example.com
export GIT_COMMITTER_NAME=check GIT_COMMITTER_EMAIL=check@example.com
mkdir -p "$HOME" "$GH"
git config --global init.defaultBranch main
git config --global advice.detachedHead false

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
reset() {
  kill_sessions
  rm -rf "$HOME" "$UNITS" "$GH" "$work/ops"
  mkdir -p "$HOME" "$GH"
  : >"$CALLS"
}
called() { grep -qxF "$1" "$CALLS" || { cat "$CALLS" >&2; fail "expected call: $1"; }; }
not_called() { ! grep -qF "$1" "$CALLS" || { cat "$CALLS" >&2; fail "unexpected call: $1"; }; }
active() { [ -e "$UNITS/claude-rc@$1.service" ]; }
enabled() { grep -qxF "$1" "$HOME/.local/state/factory/enabled" 2>/dev/null; }
# Runs a command that must fail with exit code $1.
exits() {
  local want="$1" got=0
  shift
  "$@" >"$work/out" 2>&1 || got=$?
  [ "$got" -eq "$want" ] || { cat "$work/out" >&2; fail "'$*' exited $got, expected $want"; }
}

# A live session: a process with --sdk-url in its command line, working in $1.
sessions=()
start_session() {
  (cd "$1" && exec bash -c 'sleep 300; true' session --sdk-url) &
  sessions+=("$!")
}
kill_sessions() {
  [ "${#sessions[@]}" -eq 0 ] || kill "${sessions[@]}" 2>/dev/null || true
  sessions=()
}
# A process that was killed stays a zombie until reaped, so check its state.
alive() { [ -e "/proc/$1" ] && [ "$(cut -d " " -f 3 "/proc/$1/stat")" != Z ]; }

# origin.git has one commit on main; clone_repo puts a clone of it in ~/repos.
git init --quiet --bare "$work/origin.git"
git clone --quiet "$work/origin.git" "$work/seed" 2>/dev/null
git -C "$work/seed" commit --quiet --allow-empty -m init
git -C "$work/seed" push --quiet origin main
clone_repo() { git clone --quiet "$work/origin.git" "$HOME/repos/$1" 2>/dev/null; }
# A worktree of repository $1 named $2, on its own branch, pushed.
add_worktree() {
  local wt="$HOME/repos/$1/.claude/worktrees/$2"
  git -C "$HOME/repos/$1" worktree add --quiet -b "$2" "$wt" 2>/dev/null
  git -C "$wt" push --quiet origin "$2" 2>/dev/null
  echo "$wt"
}
# Result links of builds, registered as indirect GC roots the way Nix does.
# Stale: one in /tmp, one in a kept cache and one whose path has a space, all
# made three days ago. Kept: one in /tmp made now, a worktree's root in
# ~/.gcroots and a `nix develop --profile` generation link in ~/.cache, both
# made three days ago. Swapped: registered under /tmp, then its parent turned
# into a symlink to a directory outside, as an attacker would.
old_tmp_root="$work/tmp/build/result" new_tmp_root="$work/tmp/fresh/result"
spaced_root="$work/tmp/a b/result" spaced_prefix="$work/tmp/a"
old_cache_root="$HOME/.cache/nix/result" worktree_root="$HOME/.gcroots/origin/wt"
shell_root="$HOME/.cache/shell-1-link"
swapped_root="$work/tmp/swap/victim" outside_link="$work/outside/victim"
add_roots() {
  rm -rf "$work/tmp" "$work/gcroots" "$work/outside"
  mkdir -p "$work/store/pinned"
  add_root "$old_tmp_root" '3 days ago'
  add_root "$new_tmp_root" now
  add_root "$spaced_root" '3 days ago'
  touch "$spaced_prefix"
  add_root "$old_cache_root" '3 days ago'
  add_root "$worktree_root" '3 days ago'
  add_root "$shell_root" '3 days ago'
  add_root "$swapped_root" '3 days ago'
  rm -rf "$work/tmp/swap"
  mkdir -p "$work/outside"
  ln -sfn "$work/store/pinned" "$outside_link"
  touch -h -d '3 days ago' "$outside_link"
  ln -sfn "$work/outside" "$work/tmp/swap"
}
add_root() {
  mkdir -p "$(dirname "$1")" "$work/gcroots/auto"
  ln -sfn "$work/store/pinned" "$1"
  touch -h -d "$2" "$1"
  ln -sfn "$1" "$work/gcroots/auto/$(echo "$1" | sha1sum | cut -c 1-32)"
}
# Whether Nix still counts the link $1 as a GC root.
registered() {
  local link
  for link in "$work/gcroots/auto"/*; do
    [ "$(readlink "$link")" != "$1" ] || return 0
  done
  return 1
}
# Nothing outside the stale result links is touched: not a fresh root, a
# worktree's or a dev shell's, nor what a path with a space or a swapped
# parent leads to.
kept_what_must_stay() {
  [ -L "$new_tmp_root" ] || fail "a fresh GC root was removed"
  [ -L "$worktree_root" ] || fail "a worktree's GC root was removed"
  [ -L "$shell_root" ] || fail "a dev shell's GC root was removed"
  [ -e "$spaced_prefix" ] || fail "a path with a space was split into another path"
  [ -L "$outside_link" ] || fail "a symlinked parent led the delete outside"
}

# ─── Launchers ───────────────────────────────────────────────────────────────

echo "factory-rc: applies the flavor, trusts the repo, starts Remote Control"
reset
clone_repo origin
echo '{"projects":{"/elsewhere":{"hasTrustDialogAccepted":true}}}' >"$HOME/.claude.json"
printf 'ghp_check' >"$work/gh-token"
factory-rc origin
called "claude-factory --version"
called "claude remote-control --name origin $repoArgs GH_TOKEN=ghp_check PWD=$HOME/repos/origin"
[ "$(jq '.projects["'"$HOME/repos/origin"'"].hasTrustDialogAccepted' "$HOME/.claude.json")" = true ] ||
  fail "repo was not trusted"
[ "$(jq '.projects["/elsewhere"].hasTrustDialogAccepted' "$HOME/.claude.json")" = true ] ||
  fail "trusting one repo lost another's trust"
[ "$(jq '.remoteDialogSeen' "$HOME/.claude.json")" = true ] ||
  fail "Remote Control would wait on its first-run prompt"

echo "factory-rc: refuses a directory that is not a clone, and unsafe names"
reset
mkdir -p "$HOME/repos/plain"
exits 1 factory-rc plain
if factory-rc "" >/dev/null 2>&1; then fail "factory-rc accepted an empty name"; fi
for bad in ".hidden" ".." "a b" "a/b" 'a$b'; do
  exits 1 factory-rc "$bad"
done
[ ! -s "$CALLS" ] || fail "factory-rc ran Claude for a refused name"

echo "factory-rc-admin: serves ~/admin, one directory for every session"
reset
factory-rc-admin
called "claude remote-control --name admin $adminArgs GH_TOKEN=ghp_check PWD=$HOME/admin"
[ "$(jq '.projects["'"$HOME/admin"'"].hasTrustDialogAccepted' "$HOME/.claude.json")" = true ] ||
  fail "~/admin was not trusted"
jq -e '.permissions.allow | index("Bash(factory-ctl *)")' "$adminSettings" >/dev/null ||
  fail "the admin agent is not allowed to run factory-ctl"

# ─── factory-ctl start / stop / restart / resolve ───────────────────────────

echo "start: clones a URL under its name, enables and starts it; rerunning is a no-op"
reset
factory-ctl start "file://$work/origin.git" >/dev/null
[ -d "$HOME/repos/origin/.git" ] || fail "origin was not cloned"
active origin || fail "origin was not started"
enabled origin || fail "origin was not enabled"
touch "$HOME/repos/origin/marker"
factory-ctl start "file://$work/origin.git" >/dev/null
[ -e "$HOME/repos/origin/marker" ] || fail "an existing clone was replaced"
[ "$(grep -c . "$HOME/.local/state/factory/enabled")" -eq 1 ] || fail "origin was enabled twice"

echo "start: derives the name from ssh and https URLs; an explicit name wins"
reset
mkdir -p "$HOME/repos/repo" "$HOME/repos/other" "$HOME/repos/custom"
factory-ctl start git@github.com:owner/repo.git >/dev/null
factory-ctl start https://github.com/owner/other >/dev/null
factory-ctl start "file://$work/origin.git" custom >/dev/null
active repo && active other && active custom || fail "a URL was mapped to the wrong name"

echo "start: a bare name serves its clone, or exits 3 when there is none"
reset
clone_repo origin
factory-ctl start origin >/dev/null
active origin || fail "the clone was not started"
exits 3 factory-ctl start missing
active missing && fail "started a repository that is not cloned"
enabled missing && fail "enabled a repository that is not cloned"

echo "start / stop / restart: refuse unsafe names"
reset
for bad in ".hidden" ".." "a b" 'a$b'; do
  exits 1 factory-ctl start "$bad"
  exits 1 factory-ctl stop "$bad"
done
exits 1 factory-ctl start "file://$work/.git"
[ ! -s "$CALLS" ] || fail "a unit was touched for an unsafe name"

echo "stop: stops and disables a repository with nothing at risk"
reset
clone_repo origin
add_worktree origin pushed >/dev/null
factory-ctl start origin >/dev/null
factory-ctl stop origin >/dev/null
active origin && fail "origin still runs"
enabled origin && fail "origin would start at boot"
factory-ctl stop origin >/dev/null || fail "stopping twice failed"

echo "stop: exits 2 on a live session, uncommitted or unpushed work; --force stops"
for risk in session uncommitted unpushed; do
  reset
  clone_repo origin
  wt=$(add_worktree origin work)
  case "$risk" in
    session) start_session "$wt" ;;
    uncommitted) touch "$wt/new-file" ;;
    unpushed) git -C "$wt" commit --quiet --allow-empty -m local ;;
  esac
  factory-ctl start origin >/dev/null
  exits 2 factory-ctl stop origin
  grep -q "origin" "$work/out" || fail "the refusal did not say what is at risk ($risk)"
  active origin && enabled origin || fail "a refused stop changed state ($risk)"
  factory-ctl stop --force origin >/dev/null
  active origin || enabled origin && fail "--force did not stop ($risk)"
done

echo "restart: restarts an enabled repository, refuses one that is off"
reset
clone_repo origin
exits 1 factory-ctl restart origin
factory-ctl start origin >/dev/null
factory-ctl restart origin >/dev/null
called "systemctl --user restart claude-rc@origin.service"

echo "resolve: finds the bot's repositories by name, case-insensitively"
reset
echo '[{"name":"Deslop","ssh_url":"git@github.com:a/Deslop.git"},{"name":"deslop","ssh_url":"git@github.com:b/deslop.git"},{"name":"x","ssh_url":"git@github.com:a/x.git"}]' >"$GH/user-repos.json"
[ "$(factory-ctl resolve deslop | wc -l)" -eq 2 ] || fail "resolve missed a match"
exits 1 factory-ctl resolve nothing

# ─── factory-ctl terminate ───────────────────────────────────────────────────

echo "terminate: ends repository sessions, never the admin's, keeps servers running"
reset
clone_repo origin
wt=$(add_worktree origin clean)
factory-ctl start origin >/dev/null
start_session "$wt"
repo_session="${sessions[-1]}"
mkdir -p "$HOME/admin"
start_session "$HOME/admin"
admin_session="${sessions[-1]}"
factory-ctl terminate >/dev/null
sleep 1
alive "$repo_session" && fail "the repository session survived"
alive "$admin_session" || fail "the admin session was ended"
active origin || fail "the server was stopped"
factory-ctl terminate | grep -q "No live sessions" || fail "terminate with nothing to end"

echo "terminate: exits 2 when a session has local work; --force ends it"
reset
clone_repo origin
wt=$(add_worktree origin busy)
touch "$wt/new-file"
start_session "$wt"
exits 2 factory-ctl terminate origin
alive "${sessions[-1]}" || fail "a refused terminate ended the session"
factory-ctl terminate --force origin >/dev/null
sleep 1
alive "${sessions[-1]}" && fail "--force did not end the session"
[ -e "$wt/new-file" ] || fail "terminate deleted work"

# ─── factory-ctl boot ────────────────────────────────────────────────────────

echo "boot: adopts existing clones once, bootstraps declared repos, survives a failure"
reset
clone_repo by-hand
exits 1 factory-boot
[ -d "$HOME/repos/declared/.git" ] || fail "the declared repo was not cloned"
active declared && active by-hand || fail "boot did not start every enabled repo"
not_called "claude-rc@unreachable"
enabled unreachable && fail "a repo that failed to clone was enabled"

echo "boot: a stopped repository stays stopped, declared or not"
factory-ctl stop declared >/dev/null
factory-ctl stop by-hand >/dev/null
rm -rf "$UNITS"
exits 1 factory-boot
active declared && fail "boot restarted a stopped declared repo"
active by-hand && fail "boot restarted a stopped repo"

# ─── factory-ctl status / stats / free-disk ─────────────────────────────────

echo "status: one row per server, then the last root operation and token warning"
reset
clone_repo origin
wt=$(add_worktree origin dirty)
touch "$wt/new-file"
factory-ctl start origin >/dev/null
clone_repo parked
mkdir -p "$work/ops"
jq -n '{op: "deploy", state: "success", sha: "abcdef1234567", message: "Deployed", at: "now"}' >"$work/ops/last.json"
date -d '+5 days' '+%F %T UTC' >"$work/ops/token-expires"
factory-ctl status >"$work/out"
grep -Eq '^admin +inactive +0 session' "$work/out" || fail "no admin row"
grep -Eq '^origin +on +0 session.*1 worktree' "$work/out" || fail "origin's row is wrong"
grep -Eq '^parked +off ' "$work/out" || fail "parked's row is wrong"
grep -q 'Last deploy: success abcdef1' "$work/out" || fail "the last deploy is missing"
grep -q 'WARNING: the deploy token expires' "$work/out" || fail "no expiry warning"

echo "stats: reports RAM, disk, CPU and uptime"
factory-ctl stats >"$work/out"
grep -q '^RAM ' "$work/out" && grep -q '^Disk ' "$work/out" && grep -q '^CPU ' "$work/out" && grep -Eq '^Up +[0-9]+d' "$work/out" ||
  { cat "$work/out" >&2; fail "stats is missing a line"; }

echo "free-disk: prunes only worktrees that lose nothing, throwaway caches and stale GC roots"
reset
clone_repo origin
pushed=$(add_worktree origin pushed)
dirty=$(add_worktree origin dirty)
touch "$dirty/new-file"
unpushed=$(add_worktree origin unpushed)
git -C "$unpushed" commit --quiet --allow-empty -m local
busy=$(add_worktree origin busy)
start_session "$busy"
mkdir -p "$HOME/.cache/npm" "$HOME/.cache/nix" "$HOME/.cache/cabal/logs" "$HOME/.cache/cabal/packages"
add_roots
factory-ctl free-disk plan >"$work/out"
grep -q "origin/.claude/worktrees/pushed" "$work/out" || fail "plan misses the pushed worktree"
grep -qF "$old_tmp_root" "$work/out" && grep -qF "$old_cache_root" "$work/out" || fail "plan misses a stale GC root"
grep -qF -e "$new_tmp_root" -e "$worktree_root" -e "$shell_root" "$work/out" && fail "plan lists a GC root that must stay"
grep -Eq "worktrees/(dirty|unpushed|busy)" "$work/out" && fail "plan lists a worktree with work"
grep -q ".cache/npm" "$work/out" || fail "plan misses a cache"
grep -Eq '\.cache/nix$|\.cache/cabal/packages$' "$work/out" && fail "plan lists a cache that keeps builds fast"
factory-ctl free-disk apply >"$work/out"
grep -Eq '^Freed -?[0-9]+\.[0-9] GB$' "$work/out" || fail "apply does not report the space freed in GB"
[ ! -e "$old_tmp_root" ] && [ ! -e "$old_cache_root" ] && [ ! -e "$spaced_root" ] || fail "a stale GC root was kept"
kept_what_must_stay
[ ! -e "$pushed" ] || fail "the pushed worktree was kept"
[ -e "$dirty/new-file" ] && [ -d "$unpushed" ] && [ -d "$busy" ] || fail "a worktree with work was removed"
[ ! -e "$HOME/.cache/npm" ] && [ ! -e "$HOME/.cache/cabal/logs" ] || fail "a cache was kept"
[ -d "$HOME/.cache/nix" ] && [ -d "$HOME/.cache/cabal/packages" ] || fail "a cache that keeps builds fast was removed"
called "nix-store --gc"

echo "free-disk: deletes /qa runs untouched for a day, never login state or scripts"
reset
clone_repo origin
qa="$HOME/.cache/qa/owner/origin"
mkdir -p "$qa/runs/12-old" "$qa/runs/13-live" "$qa/auth" "$qa/scripts"
echo video >"$qa/runs/12-old/happy-path.mp4"
# A QA worktree with a change, so worktree remove leaves it to the run.
git -C "$HOME/repos/origin" worktree add --quiet --detach "$qa/runs/12-old/worktree" 2>/dev/null
touch "$qa/runs/12-old/worktree/new-file"
find "$qa/runs/12-old" -exec touch -d '2 days ago' {} +
echo video >"$qa/runs/13-live/happy-path.mp4"
# A live run's clean worktree, which a pushed-and-clean check alone would take.
git -C "$HOME/repos/origin" worktree add --quiet --detach "$qa/runs/13-live/worktree"
echo '{}' >"$qa/auth/user.json"
echo '// lib' >"$qa/scripts/lib.cjs"
touch -d '2 days ago' "$qa/auth/user.json" "$qa/scripts/lib.cjs"
factory-ctl free-disk plan >"$work/out"
grep -q "owner/origin/runs/12-old" "$work/out" || fail "plan misses a finished QA run"
grep -Eq "runs/13-live|/auth|/scripts" "$work/out" && fail "plan lists a live QA run, login state or scripts"
factory-ctl free-disk apply >"$work/out"
grep -Eq '^Freed -?[0-9]+\.[0-9] GB$' "$work/out" || fail "apply does not report the space freed in GB"
[ ! -e "$qa/runs/12-old" ] || fail "a finished QA run was kept"
git -C "$HOME/repos/origin" worktree list | grep -q 12-old && fail "a deleted run's worktree is still registered"
[ -e "$qa/runs/13-live/happy-path.mp4" ] || fail "a live QA run was removed"
[ -d "$qa/runs/13-live/worktree" ] || fail "a live QA run's clean worktree was removed"
[ -e "$qa/auth/user.json" ] && [ -e "$qa/scripts/lib.cjs" ] || fail "QA login state or scripts were removed"

# ─── factory-ctl deploy / rollback / reboot / gc ─────────────────────────────

echo "deploy: dispatches the workflow on main and waits for it"
reset
factory-ctl deploy >/dev/null
called "gh workflow run deploy-factory.yml --repo owner/nixos --ref main"
called "gh run watch 42 --repo owner/nixos --exit-status"
reset
touch "$GH/run-fails"
exits 1 factory-ctl deploy
grep -q "actions/runs/42" "$work/out" || fail "a failed request gave no link"

echo "rollback / reboot / gc: start their fixed root unit"
for op in rollback reboot gc; do
  reset
  factory-ctl "$op" >/dev/null
  called "systemctl start --no-block factory-$op.service"
done

# ─── Root: factory-deploy ────────────────────────────────────────────────────

# Two systems whose activation is recorded, the running one being old.
make_system() {
  mkdir -p "$work/systems/$1/bin"
  printf '#!/bin/sh\necho "%s $*" >>"$CALLS"\n' "$1" >"$work/systems/$1/bin/switch-to-configuration"
  chmod +x "$work/systems/$1/bin/switch-to-configuration"
}
deploy_reset() {
  reset
  rm -rf "$work/systems" "$work/profiles"
  make_system old
  make_system new
  mkdir -p "$work/profiles"
  ln -sfn "$work/systems/old" "$work/current-system"
  ln -sfn "$work/systems/old" "$work/profiles/system"
  printf 'github_pat_secret' >"$work/deploy-token"
  echo '[{"id": 7, "sha": "abc123"}]' >"$GH/deployments.json"
  echo '[]' >"$GH/statuses.json"
  echo '{"sha": "abc123"}' >"$GH/main.json"
}
posted() { jq -s -r 'map(.state) | join(" ")' "$GH/posted"; }

echo "factory-deploy: nothing pending is a no-op"
deploy_reset
echo '[]' >"$GH/deployments.json"
factory-deploy
not_called "nix "
deploy_reset
echo '[{"state": "success"}]' >"$GH/statuses.json"
factory-deploy
not_called "nix "

echo "factory-deploy: builds the tip of main, tests it, then makes it the boot default"
deploy_reset
factory-deploy >/dev/null
called "nix build --no-link --print-out-paths github:owner/nixos/abc123#nixosConfigurations.software-factory.config.system.build.toplevel"
called "new test"
called "new boot"
[ "$(readlink "$work/profiles/system")" = "$work/systems/new" ] || fail "the profile was not set"
[ "$(posted)" = "in_progress success" ] || fail "posted $(posted)"
[ "$(jq -r .state "$work/ops/last.json")" = success ] || fail "the result was not recorded"
grep -q 2027-01-01 "$work/ops/token-expires" || fail "the token expiry was not recorded"

echo "factory-deploy: the token travels in curl's config, never in argv"
grep -q 'github_pat_secret' "$GH/config" || fail "the token was not sent"
grep -q 'github_pat_secret' "$CALLS" && fail "the token appeared in argv"

echo "factory-deploy: refuses anything but the tip of main, so an older commit of it cannot be deployed"
deploy_reset
echo '{"sha": "def456"}' >"$GH/main.json"
exits 1 factory-deploy
not_called "nix build"
[ "$(posted)" = "in_progress failure" ] || fail "posted $(posted)"

echo "factory-deploy: a failed build changes nothing"
deploy_reset
touch "$GH/build-fails"
exits 1 factory-deploy
not_called "new test"
[ "$(posted)" = "in_progress failure" ] || fail "posted $(posted)"

echo "factory-deploy: a failed health gate goes back to the old system"
for broken in sshd github; do
  deploy_reset
  case "$broken" in
    sshd) export SSHD_UP=0 ;;
    github) touch "$GH/github-down" ;;
  esac
  exits 1 factory-deploy
  unset SSHD_UP
  called "new test"
  called "old test"
  not_called "new boot"
  [ "$(readlink "$work/profiles/system")" = "$work/systems/old" ] || fail "the boot default moved ($broken)"
  grep -q "rolled back" "$work/ops/last.json" || fail "the rollback was not recorded ($broken)"
done

echo "factory-deploy: the running system is not switched again"
deploy_reset
ln -sfn "$work/systems/new" "$work/current-system"
factory-deploy >/dev/null
not_called "new test"
[ "$(posted)" = "in_progress success" ] || fail "posted $(posted)"

# ─── Dev shell roots ─────────────────────────────────────────────────────────

echo "root-shells: roots main's shell and locked inputs without its hook, replaced each run, never a flake-less repo"
reset
git init --quiet --bare --initial-branch main "$work/flaked.git"
git clone --quiet "$work/flaked.git" "$work/flaked" 2>/dev/null
touch "$work/flaked/flake.nix"
git -C "$work/flaked" add flake.nix
git -C "$work/flaked" commit --quiet -m flake
git -C "$work/flaked" push --quiet origin main
git clone --quiet "$work/flaked.git" "$HOME/repos/shop"
git clone --quiet "$work/flaked.git" "$HOME/repos/broken"
clone_repo plain
echo '{"path": "/nix/store/a-source", "inputs": {"x": {"path": "/nix/store/b-source", "inputs": {"y": {"path": "/nix/store/a-source"}}}}}' >"$GH/flake-archive.json"
mkdir -p "$HOME/.gcroots/shop/inputs"
ln -s /nix/store/old-source "$HOME/.gcroots/shop/inputs/old-source"
exits 1 factory-ctl root-shells
grep -q "could not root the dev shell of broken" "$work/out" || fail "the failed repository is not named"
shop="git+file://$HOME/repos/shop?ref=refs/remotes/origin/main"
called "nix print-dev-env $shop --profile $HOME/.gcroots/shop/default"
[ ! -e "$GH/shell-hook-ran" ] || fail "root-shells ran a shellHook"
called "nix profile wipe-history --profile $HOME/.gcroots/shop/default"
[ "$(find "$HOME/.gcroots/shop/inputs" -mindepth 1 -printf '%f\n' | sort | paste -sd ' ')" = "a-source b-source" ] || fail "the input roots are not exactly the locked inputs"
[ -L "$HOME/.gcroots/broken/inputs/a-source" ] || fail "a repository without a shell lost its input roots"
not_called "repos/plain?"

# ─── Skills ──────────────────────────────────────────────────────────────────

# Two farms holding the same skill, as two generations do.
skills="$HOME/.claude/skills"
skills_reset() {
  reset
  rm -rf "$work/farm-a" "$work/farm-b"
  mkdir -p "$skills" "$work/farm-a/alpha" "$work/farm-a/beta" "$work/farm-b/alpha"
}

status_reports() {
  factory-ctl status >"$work/out"
  grep -qxF "$1" "$work/out" || { cat "$work/out" >&2; fail "status does not report: $1"; }
}

echo "factory-relink-skills: replaces links a GC left dangling; status counts them, then none"
skills_reset
ln -s "$work/collected/alpha" "$skills/alpha"
ln -s "$work/collected/gamma" "$skills/gamma"
ln -s "$work/farm-a/beta" "$skills/beta"
status_reports "Skills: 2 dangling link(s): alpha gamma"
factory-relink-skills "$work/farm-a"
[ "$(readlink "$skills/alpha")" = "$work/farm-a/alpha" ] || fail "alpha was not relinked"
[ ! -L "$skills/gamma" ] || fail "a link of the old farm survived"
status_reports "Skills: 0 dangling links"

echo "factory-relink-skills: works on a first run with no ~/.claude"
skills_reset
rm -rf "$HOME/.claude"
factory-relink-skills "$work/farm-a"
[ "$(readlink "$skills/beta")" = "$work/farm-a/beta" ] || fail "the first run linked nothing"

echo "factory-relink-skills: a skill never goes missing while it swaps farms"
skills_reset
factory-relink-skills "$work/farm-a"
(
  while [ ! -e "$work/stop-reading" ]; do
    [ -e "$skills/alpha" ] || touch "$work/skill-missing"
  done
) &
reader=$!
for _ in $(seq 40); do
  factory-relink-skills "$work/farm-b"
  factory-relink-skills "$work/farm-a"
done
touch "$work/stop-reading"
wait "$reader"
rm -f "$work/stop-reading"
[ ! -e "$work/skill-missing" ] || fail "a reader saw the skill missing during a relink"

echo "factory-relink-skills: waits for the lock, and gives up without failing"
skills_reset
factory-relink-skills "$work/farm-a"
exec 8>"$HOME/.claude/.factory.lock"
flock 8
factory-relink-skills "$work/farm-b" 2>"$work/out"
exec 8>&-
grep -q "left ~/.claude/skills as it was" "$work/out" || fail "the skipped relink says nothing"
[ "$(readlink "$skills/alpha")" = "$work/farm-a/alpha" ] || fail "relinked without holding the lock"
factory-relink-skills "$work/farm-b"
[ "$(readlink "$skills/alpha")" = "$work/farm-b/alpha" ] || fail "did not relink once the lock was free"

# ─── Root: factory-maintenance ───────────────────────────────────────────────

echo "factory-maintenance rollback: switches to the previous generation"
deploy_reset
ln -sfn "$work/systems/new" "$work/profiles/system"
factory-maintenance rollback >/dev/null
called "old switch"
[ "$(jq -r '.op + " " + .state' "$work/ops/last.json")" = "rollback success" ] || fail "rollback not recorded"

echo "factory-maintenance gc: keeps two generations of the system profile, drops stale GC roots"
deploy_reset
add_roots
factory-maintenance gc >/dev/null
called "nix-env -p $work/profiles/system --delete-generations +2"
called "nix-store --gc"
kept_what_must_stay
! registered "$old_tmp_root" && ! registered "$old_cache_root" && ! registered "$spaced_root" || fail "a stale GC root is still registered"
registered "$new_tmp_root" && registered "$worktree_root" && registered "$shell_root" || fail "a GC root that must stay was unregistered"
jq -r .message "$work/ops/last.json" | grep -Eq '^Freed -?[0-9]+\.[0-9] GB$' || fail "gc does not report the space freed in GB"

echo "factory-maintenance reboot: refused within 10 minutes of boot"
deploy_reset
if [ "$(cut -d . -f 1 /proc/uptime)" -lt 600 ]; then
  exits 1 factory-maintenance reboot
  not_called "systemctl reboot"
else
  factory-maintenance reboot >/dev/null
  called "systemctl reboot"
fi

kill_sessions
