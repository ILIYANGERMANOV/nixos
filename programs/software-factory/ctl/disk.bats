#!/usr/bin/env bats
# shellcheck disable=SC2154,SC2312 # test_helper and check.nix set the variables, and a masked failure fails the assertion around it

load ../test_helper

@test "free-disk: prunes only worktrees that lose nothing, throwaway caches and stale GC roots" {
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
  { grep -qF "$old_tmp_root" "$work/out" && grep -qF "$old_cache_root" "$work/out"; } || fail "plan misses a stale GC root"
  ! grep -qF -e "$new_tmp_root" -e "$worktree_root" -e "$shell_root" "$work/out" || fail "plan lists a GC root that must stay"
  ! grep -Eq "worktrees/(dirty|unpushed|busy)" "$work/out" || fail "plan lists a worktree with work"
  grep -q ".cache/npm" "$work/out" || fail "plan misses a cache"
  ! grep -Eq '\.cache/nix$|\.cache/cabal/packages$' "$work/out" || fail "plan lists a cache that keeps builds fast"

  factory-ctl free-disk apply >"$work/out"

  reports_freed_gb
  [ ! -e "$old_tmp_root" ] && [ ! -e "$old_cache_root" ] && [ ! -e "$spaced_root" ] || fail "a stale GC root was kept"
  kept_what_must_stay
  [ ! -e "$pushed" ] || fail "the pushed worktree was kept"
  [ -e "$dirty/new-file" ] && [ -d "$unpushed" ] && [ -d "$busy" ] || fail "a worktree with work was removed"
  [ ! -e "$HOME/.cache/npm" ] && [ ! -e "$HOME/.cache/cabal/logs" ] || fail "a cache was kept"
  [ -d "$HOME/.cache/nix" ] && [ -d "$HOME/.cache/cabal/packages" ] || fail "a cache that keeps builds fast was removed"
  called "nix-store --gc"
}

@test "free-disk: keeps a /10x-engineer run's clean, pushed worktree" {
  clone_repo origin
  tenx="$HOME/.10x/2026-01-01-run/worktrees/task"
  add_worktree origin task "$tenx"

  factory-ctl free-disk plan >"$work/out"
  ! grep -q ".10x/" "$work/out" || fail "plan lists a /10x-engineer run's worktree"

  factory-ctl free-disk apply
  [ -d "$tenx" ] || fail "a /10x-engineer run's worktree was removed"
}

@test "free-disk: keeps a worktree whose state cannot be read" {
  clone_repo origin
  broken=$(add_worktree origin broken)
  echo 'gitdir: /nowhere' >"$broken/.git"

  factory-ctl free-disk plan >"$work/out"
  ! grep -q "worktrees/broken" "$work/out" || fail "plan lists an unreadable worktree"

  factory-ctl free-disk apply
  [ -e "$broken/.git" ] || fail "an unreadable worktree was removed"
}

@test "free-disk: keeps a worktree that lost its .git" {
  clone_repo origin
  lost=$(add_worktree origin lost)
  rm "$lost/.git"

  factory-ctl free-disk plan >"$work/out"
  ! grep -q "worktrees/lost" "$work/out" || fail "plan lists a worktree it cannot read"

  factory-ctl free-disk apply
  [ -d "$lost" ] || fail "a worktree that lost its .git was removed"
}

@test "free-disk: keeps a locked worktree" {
  clone_repo origin
  locked=$(add_worktree origin locked)
  git -C "$HOME/repos/origin" worktree lock "$locked"

  factory-ctl free-disk plan >"$work/out"
  ! grep -q "worktrees/locked" "$work/out" || fail "plan lists a locked worktree"

  factory-ctl free-disk apply
  [ -d "$locked" ] || fail "a locked worktree was removed"
}

@test "free-disk: removes a cache whose name holds a newline" {
  clone_repo origin
  odd="$HOME/.cache/odd"$'\n'name
  mkdir -p "$odd"

  factory-ctl free-disk apply

  [ ! -e "$odd" ] || fail "the cache was kept"
}

@test "free-disk: removes a stale GC root whose path holds a newline, and nothing the path spells" {
  clone_repo origin
  spelled="$work/spelled"
  touch "$spelled"
  odd="$work/tmp/old"$'\n'"$spelled"
  add_root "$odd" '3 days ago'

  factory-ctl free-disk apply

  [ ! -L "$odd" ] || fail "the stale GC root was kept"
  [ -e "$spelled" ] || fail "a line of the path was removed as a path"
}

@test "free-disk: deletes /qa runs untouched for a day, never login state or scripts" {
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
  ! grep -Eq "runs/13-live|/auth|/scripts" "$work/out" || fail "plan lists a live QA run, login state or scripts"

  factory-ctl free-disk apply >"$work/out"

  reports_freed_gb
  [ ! -e "$qa/runs/12-old" ] || fail "a finished QA run was kept"
  git -C "$HOME/repos/origin" worktree list >"$work/worktrees"
  ! grep -q 12-old "$work/worktrees" || fail "a deleted run's worktree is still registered"
  [ -e "$qa/runs/13-live/happy-path.mp4" ] || fail "a live QA run was removed"
  [ -d "$qa/runs/13-live/worktree" ] || fail "a live QA run's clean worktree was removed"
  [ -e "$qa/auth/user.json" ] && [ -e "$qa/scripts/lib.cjs" ] || fail "QA login state or scripts were removed"
}

@test "free-disk: keeps a worktree whose session started after the plan decided on it" {
  clone_repo a-first
  clone_repo z-last
  late=$(add_worktree a-first late)
  session_starts_during_scan_of z-last "$late"

  factory-ctl free-disk apply >"$work/out"

  [ -d "$late" ] || fail "a worktree with a live session was removed"
  grep -q "kept a-first/.claude/worktrees/late" "$work/out" || fail_showing "$work/out" "the kept worktree is not reported"
  reports_freed_gb
}

@test "free-disk: keeps a quiet /qa run a live session works in" {
  clone_repo origin
  run="$HOME/.cache/qa/owner/origin/runs/12-busy"
  git -C "$HOME/repos/origin" worktree add --quiet --detach "$run/worktree" 2>/dev/null
  find "$run" -exec touch -d '2 days ago' {} +
  start_session "$run/worktree"

  factory-ctl free-disk apply >"$work/out"

  [ -d "$run/worktree" ] || fail "a /qa run with a live session was removed"
  grep -q "kept .cache/qa/owner/origin/runs/12-busy" "$work/out" || fail_showing "$work/out" "the kept run is not reported"
}

# A session moves into $2 while the plan reads repository $1, which sorts after
# the repository of $2: the plan has already decided on $2. Git runs a fsmonitor
# program from `git status`, and the program returns once the session is there.
session_starts_during_scan_of() {
  local arrive="$work/session-arrive" arrived="$work/session-arrived"
  # shellcheck disable=SC2016 # expands in the session
  in_background bash -c 'until [ -e "$2" ]; do sleep 0.01; done; cd "$3" && touch "$4" && sleep 300; true' session --sdk-url "$arrive" "$2" "$arrived"
  cat >"$work/fsmonitor" <<EOF
#!$BASH
touch "$arrive"
until [ -e "$arrived" ]; do sleep 0.01; done
exit 1
EOF
  chmod +x "$work/fsmonitor"
  git -C "$HOME/repos/$1" config core.fsmonitor "$work/fsmonitor"
}

# Clones $@ of a repository with a flake on main.
clone_flaked() {
  git init --quiet --bare --initial-branch main "$work/flaked.git"
  git clone --quiet "$work/flaked.git" "$work/flaked" 2>/dev/null
  touch "$work/flaked/flake.nix"
  git -C "$work/flaked" add flake.nix
  git -C "$work/flaked" commit --quiet -m flake
  git -C "$work/flaked" push --quiet origin main
  local name
  for name in "$@"; do
    git clone --quiet "$work/flaked.git" "$HOME/repos/$name"
  done
}

@test "root-shells: roots main's shell and locked inputs without its hook, replaced each run, never a flake-less repo" {
  clone_flaked shop broken
  clone_repo plain
  echo '{"path": "/nix/store/a-source", "inputs": {"x": {"path": "/nix/store/b-source", "inputs": {"y": {"path": "/nix/store/a-source"}}}}}' >"$GH/flake-archive.json"
  mkdir -p "$HOME/.gcroots/shop/inputs"
  ln -s /nix/store/old-source "$HOME/.gcroots/shop/inputs/old-source"

  run -1 factory-ctl root-shells

  grep -q "could not root the dev shell of broken" <<<"$output" || fail "the failed repository is not named"
  shop="git+file://$HOME/repos/shop?ref=refs/remotes/origin/main"
  called "nix print-dev-env $shop --profile $HOME/.gcroots/shop/default"
  [ ! -e "$GH/shell-hook-ran" ] || fail "root-shells ran a shellHook"
  called "nix profile wipe-history --profile $HOME/.gcroots/shop/default"
  [ "$(find "$HOME/.gcroots/shop/inputs" -mindepth 1 -printf '%f\n' | sort | paste -sd ' ')" = "a-source b-source" ] || fail "the input roots are not exactly the locked inputs"
  [ -L "$HOME/.gcroots/broken/inputs/a-source" ] || fail "a repository without a shell lost its input roots"
  not_called "repos/plain?"
}
