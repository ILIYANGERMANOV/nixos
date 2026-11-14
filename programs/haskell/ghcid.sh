# shellcheck shell=bash
# The per-worktree ghcid session behind `<name>-quick-typecheck` and
# `<name>-quick-test`: a GHCi kept warm, so asking whether the code typechecks
# costs a reload, not a build. Ported from Ivy-Apps/haskell-template's
# nix/ghcid. Nix sets before it: name (the dev shell it spawns), package_dir,
# source_dirs, test_flags, respawn_on and version.
#
# What looks arbitrary:
# - ghcid restarts on a cabal file edit: else an added module leaves a stale
#   `All good` for ever.
# - Each session touches $session before cabal reads the cabal files. A verdict
#   counts only when newer than that stamp and it newer than every cabal file:
#   ghcid can reload an edited module before it sees a cabal edit.
# - State lives outside the worktree: an output file under ghcid's watch makes
#   it re-trigger on its own writes.
# - Kills go by process tree: the GHCi ghcid owns carries nothing to match on.
# - quick-test runs in the same session through ghcid's `--test` hook, so a
#   worktree holds one GHCi. Unfiltered it runs the compiled suite, faster for
#   all of it.

idle_seconds=7200 # a session holds hundreds of MB: reclaim it after 2h unused
wait_seconds=180  # for a verdict, before giving up loudly
spawn_seconds=10  # until a spawned daemon must show in the process table
# A live daemon that has not rewritten its verdict in this long never will: the
# stale input is outside its module graph. Above a full restart's reload.
settle_seconds=30
test_seconds=600
poll_seconds=0.2
max_report_lines=200 # keeps a wide breakage from flooding an agent's context
death_log_lines=40

# Exits 0 when the package typechecks, 1 with GHC's errors when not, and 2
# with the reason when no verdict could be had.
run_quick_typecheck() {
  enter_session
  typecheck
}

# With a filter, the examples `--match` selects run in the session: exit 0 when
# they pass, 1 when they fail, none match or the code does not typecheck, 2 when
# no answer could be had. Without one, the `<name>-test` runner.
run_quick_test() {
  enter_session
  if [ "$#" -eq 0 ]; then
    exec nix run "$root#$name-test"
  fi
  typecheck
  request_run "$@"
  await_run
  report_run "$*"
}

# $1: the session's state directory. Kills the daemon after idle_seconds unused,
# and ends with it.
run_ghcid_watchdog() {
  session_paths "$1"
  local used
  while sleep 60; do
    pgrep -f "$daemon_match" >/dev/null || return 0
    used=$(stat -c %Y "$lastuse")
    if [ "$((EPOCHSECONDS - used))" -ge "$idle_seconds" ]; then
      kill_matching "$daemon_match"
      return 0
    fi
  done
}

# Run from the package directory: names this worktree's session files.
enter_session() {
  local key
  root=$(git rev-parse --show-toplevel)
  key=$(printf '%s' "$PWD" | sha256sum | cut -c1-16)
  # Cabal allows one .cabal file in a package directory.
  cabal_files=(*.cabal cabal.project)
  session_paths "${XDG_CACHE_HOME:-$HOME/.cache}/haskell-ghcid/$key"
}

session_paths() {
  state=$1
  outf=$state/out
  logf=$state/log
  stamp=$state/started
  session=$state/session
  lock=$state/lock
  lastuse=$state/lastuse
  test_request=$state/test.request
  test_trigger=$state/test.trigger
  test_report=$state/test.report
  test_result=$state/test.result
  # Unique per worktree, so it finds this daemon with no PID file to go stale.
  daemon_match="ghcid .*--outputfile $outf"
  watchdog_match="$name-ghcid-watchdog $state"
}

typecheck() {
  ensure_daemon
  local status=0
  # shellcheck disable=SC2310 # the status is the verdict
  await_verdict || status=$?
  case "$status" in
    0) report ;;
    2)
      printf '%s: the ghcid daemon exited. The end of %s:\n' "$name" "$logf" >&2
      # ghcid pads every screen it renders with blank lines.
      grep -v '^[[:space:]]*$' "$logf" | tail -n "$death_log_lines" >&2
      exit 2
      ;;
    3)
      printf '%s\n' \
        "$name: ghcid is not watching these, so they cannot be checked. A new" \
        "module needs registering in ${cabal_files[0]}; a scratch file needs deleting." >&2
      stale_inputs >&2
      exit 2
      ;;
    *)
      printf '%s: no verdict within %ss; see %s\n' "$name" "$wait_seconds" "$logf" >&2
      exit 2
      ;;
  esac
}

# Losing the lock is no error: its holder is starting the daemon we wait for.
ensure_daemon() {
  mkdir -p "$state"
  touch "$lastuse"
  # shellcheck disable=SC2310 # predicates
  if needs_start && acquire_lock; then
    # shellcheck disable=SC2310 # a predicate
    if needs_start; then
      kill_matching "$daemon_match"
      kill_matching "$watchdog_match"
      start_daemon
    fi
    rm -rf "$lock"
  fi
}

needs_start() {
  pgrep -f "$daemon_match" >/dev/null || return 0
  local stamped="" file
  [ ! -f "$stamp" ] || stamped=$(<"$stamp")
  [ "$stamped" = "$version" ] || return 0
  for file in "${respawn_on[@]}"; do
    [ ! "$root/$file" -nt "$stamp" ] || return 0
  done
  return 1
}

# `mkdir` is the portable atomic mutex: two callers at once must not each
# spawn a daemon of hundreds of MB.
acquire_lock() {
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$$" >"$lock/owner"
    return 0
  fi
  reclaim_lock
}

# Takes a lock whose owner died. Possession first: `mv` is atomic, so of two
# callers that saw the same dead owner exactly one wins, and a live owner gets
# its lock back untouched.
reclaim_lock() {
  local claim=$lock.claim.$$ owner
  mv "$lock" "$claim" 2>/dev/null || return 1
  owner=$(cat "$claim/owner" 2>/dev/null || true)
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
    mv "$claim" "$lock" 2>/dev/null || rm -rf "$claim"
    return 1
  fi
  rm -rf "$claim"
  mkdir "$lock" 2>/dev/null || return 1
  printf '%s\n' "$$" >"$lock/owner"
}

# The daemon runs in the package's dev shell, so its toolchain is evaluated
# here, once per spawn, not on every call. Its log holds this session only.
start_daemon() {
  rm -f "$outf" "$session"
  : >"$test_request"
  printf '%s\n' "$version" >"$stamp"
  : >"$logf"
  local -a restarts=()
  local file hook
  hook=$(test_hook)
  for file in "${cabal_files[@]}"; do
    restarts+=(--restart "$file")
  done
  # A subshell detaches them: macOS has no setsid.
  (
    nohup nix develop "$root#$name" --no-warn-dirty --quiet -c \
      ghcid --command "$name-repl $(printf %q "$session")" --outputfile "$outf" --no-title \
      --test "$hook" --reload "$test_trigger" "${restarts[@]}" \
      >>"$logf" 2>&1 </dev/null &
  )
  (nohup "$name-ghcid-watchdog" "$state" >>"$logf" 2>&1 </dev/null &)
}

# Returns 0 once the verdict describes what is on disk, 2 once the daemon is
# gone, 3 once it is alive but no longer reacting (an input outside its module
# graph), 1 when wait_seconds run out.
await_verdict() {
  local deadline=$((EPOCHSECONDS + wait_seconds)) wrote_at seen=0 stale first
  spawned_by=$((EPOCHSECONDS + spawn_seconds))
  settled_by=$((EPOCHSECONDS + settle_seconds))
  while [ "$EPOCHSECONDS" -lt "$deadline" ]; do
    first=""
    [ ! -s "$outf" ] || read -r first <"$outf" || true
    stale=$(stale_inputs)
    # ghcid writes this when `cabal repl` exits, then exits itself.
    if [ -n "$first" ] && [ -z "$stale" ] && [ "$first" != "Ghcid has stopped." ]; then
      return 0
    fi
    # shellcheck disable=SC2310 # a predicate
    daemon_alive || return 2
    # Every reload rewrites the verdict, so its mtime is the heartbeat.
    wrote_at=$(stat -c %Y "$outf" 2>/dev/null || echo 0)
    if [ "$wrote_at" -ne "$seen" ]; then
      seen=$wrote_at
      settled_by=$((EPOCHSECONDS + settle_seconds))
    elif [ "$seen" -gt 0 ] && [ "$EPOCHSECONDS" -ge "$settled_by" ]; then
      return 3
    fi
    sleep "$poll_seconds"
  done
  return 1
}

# A daemon spawned moments ago may not be in the process table yet.
daemon_alive() {
  [ "$EPOCHSECONDS" -lt "$spawned_by" ] || pgrep -f "$daemon_match" >/dev/null
}

# Prints what is newer than the verdict, so it does not describe the disk:
# sources against the verdict, cabal files against the session start.
stale_inputs() {
  if [ ! -f "$session" ] || [ ! "$outf" -nt "$session" ]; then
    echo "$session"
    return 0
  fi
  find "${source_dirs[@]}" -type f -name '*.hs' -newer "$outf" -print -quit 2>/dev/null
  local file
  for file in "${cabal_files[@]}"; do
    [ ! "$file" -nt "$session" ] || printf '%s\n' "$file"
  done
}

# Green is one line; red is GHC's output verbatim.
report() {
  local first=""
  read -r first <"$outf" || true
  case "$first" in
    "All good"*", at "*)
      printf '%s)\n' "${first%, at *}"
      return 0
      ;;
    "All good"*)
      printf '%s\n' "$first"
      return 0
      ;;
    *)
      print_capped "$outf"
      return 1
      ;;
  esac
}

# Prints a file, cut at a length an agent's context can afford.
print_capped() {
  local total
  total=$(wc -l <"$1" | tr -d ' ')
  head -n "$max_report_lines" "$1"
  if [ "$total" -gt "$max_report_lines" ]; then
    printf '[... %s more lines, see %s]\n' "$((total - max_report_lines))" "$1"
  fi
}

# ghcid takes no commands once running, so a run is requested through files:
# the request id, then hspec's arguments, one per line. Touching the trigger
# reloads, and after a good load the hook runs it.
request_run() {
  request_id="$$-$RANDOM-$EPOCHSECONDS"
  rm -f "$test_report" "$test_result"
  printf '%s\n' "$request_id" --no-color --format=failed-examples "${test_flags[@]}" --match "$*" >"$test_request"
  touch "$test_trigger"
}

# Waits for this request's result: one for another id is a run it cut short.
await_run() {
  local deadline=$((EPOCHSECONDS + test_seconds))
  # shellcheck disable=SC2310 # a predicate
  until own_result; do
    # shellcheck disable=SC2310 # a predicate
    if ! daemon_alive; then
      printf '%s: the daemon exited mid-run; see %s\n' "$name" "$logf" >&2
      exit 2
    fi
    # An edit between the typecheck and the run broke it.
    # shellcheck disable=SC2310 # its status is the verdict
    if [ "$outf" -nt "$test_trigger" ] && ! report >/dev/null; then
      report
      exit 1
    fi
    if [ "$EPOCHSECONDS" -ge "$deadline" ]; then
      printf '%s: no result within %ss; see %s\n' "$name" "$test_seconds" "$logf" >&2
      exit 2
    fi
    sleep "$poll_seconds"
  done
}

own_result() {
  local line=""
  [ ! -s "$test_result" ] || read -r line <"$test_result" || true
  [ "${line%% *}" = "$request_id" ]
}

# $1: the filter. The result line is `<id> <examples> <failures>`, or
# `<id> aborted: <why>`.
report_run() {
  local result
  result=$(<"$test_result")
  result=${result#"$request_id "}
  case "$result" in
    aborted:*)
      printf '%s: the run %s; see %s\n' "$name" "$result" "$logf" >&2
      exit 2
      ;;
    "0 "*)
      printf '%s: no test matches "%s"\n' "$name" "$1" >&2
      exit 1
      ;;
    *" 0") print_capped "$test_report" ;;
    *)
      print_capped "$test_report"
      exit 1
      ;;
  esac
}

# The `--test` expression: one line, every name qualified, since multi-unit
# GHCi refuses `:script` and `:module` and the hook sees no Prelude. Empty
# request: nothing. Else it empties the request, runs the suite with stdout on
# the report (`bracket` hands stdout back however the run ends), and writes
# the result.
test_hook() {
  local -a parts=(
    "do { request <- Data.List.lines Data.Functor.<$> System.IO.readFile \"$test_request\""
    "; _ <- Control.Exception.evaluate (Data.List.length request)"
    "; case request of { [] -> Control.Monad.return ()"
    "; (rid : args) -> do { System.IO.writeFile \"$test_request\" \"\""
    "; outcome <- Control.Exception.try (System.IO.withFile \"$test_report\" System.IO.WriteMode (\\report ->"
    "Control.Exception.bracket"
    "(GHC.IO.Handle.hDuplicate System.IO.stdout Control.Applicative.<* GHC.IO.Handle.hDuplicateTo report System.IO.stdout)"
    "(\\ghcid -> System.IO.hFlush System.IO.stdout Control.Monad.>> GHC.IO.Handle.hDuplicateTo ghcid System.IO.stdout)"
    "(\\_ -> System.Environment.withArgs args (Test.Hspec.Runner.hspecWithResult Test.Hspec.Runner.defaultConfig Main.spec))))"
    "; System.IO.writeFile \"$test_result\" (rid Data.List.++ \" \" Data.List.++ Data.Either.either"
    "(\\e -> \"aborted: \" Data.List.++ Control.Exception.displayException (e :: Control.Exception.SomeException))"
    "(\\summary -> Data.List.unwords (Data.List.map Text.Show.show [Test.Hspec.Runner.summaryExamples summary, Test.Hspec.Runner.summaryFailures summary]))"
    "outcome) } } }"
  )
  printf '%s ' "${parts[@]}"
}

# Kills every process matching $1 and its descendants, the whole tree listed
# before any signal, so no child is reparented out of sight mid-walk.
kill_matching() {
  local pid
  victims=()
  while read -r pid; do
    add_tree "$pid"
  done < <(pgrep -f "$1" || true)
  [ "${#victims[@]}" -gt 0 ] || return 0
  kill -TERM "${victims[@]}" 2>/dev/null || true
  sleep 0.5
  kill -KILL "${victims[@]}" 2>/dev/null || true
}

add_tree() {
  local child
  victims+=("$1")
  while read -r child; do
    add_tree "$child"
  done < <(pgrep -P "$1" || true)
}
