# checks.claude-bash-guards: the hook guards fed the same JSON Claude Code sends
# a hook, the read guard against real files and a real git repository. Exit 2
# blocks the call; exit 0 allows it.
{ pkgs }:

pkgs.runCommand "claude-bash-guards-check"
  {
    nativeBuildInputs = [
      (import ./read-guard.nix { inherit pkgs; }).bin
      (import ./wait-guard.nix { inherit pkgs; }).bin
      (import ./secret-guard.nix { inherit pkgs; }).bin
      (import ./context-guard.nix { inherit pkgs; }).bin
      pkgs.git
      pkgs.jq
    ];
  }
  ''
    status=0
    dir=$TMPDIR/work
    mkdir -p "$dir"
    cd "$dir"
    head -c 9000 /dev/zero >big-a
    head -c 9000 /dev/zero >big-b
    head -c 20000 /dev/zero >huge
    echo small >small-a
    echo small >small-b
    mkdir sub
    head -c 9000 /dev/zero >sub/big-c
    head -c 9000 /dev/zero >sub/big-d
    echo small >sub/small-c
    echo small >sub/small-d

    export HOME=$TMPDIR GIT_AUTHOR_NAME=check GIT_AUTHOR_EMAIL=check@example.com
    export GIT_COMMITTER_NAME=check GIT_COMMITTER_EMAIL=check@example.com
    git init --quiet
    git add big-a small-a
    git commit --quiet -m init

    # Runs $guard on a foreground Bash command and checks its exit code.
    expect() {
      expect_call "$1" "$2" "$3" false
    }
    # Runs $guard on a Bash command, backgrounded when $4 is true.
    expect_call() {
      local want="$1" name="$2" command="$3" background="$4"
      expect_raw "$want" "$name" "$(jq -n --arg c "$command" --arg d "$dir" --argjson b "$background" \
        '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c, run_in_background: $b}, cwd: $d}')"
    }
    # Runs $guard on raw input and checks its exit code.
    expect_raw() {
      local want="$1" name="$2" input="$3" got=0
      printf '%s' "$input" | "$guard" 2>"$TMPDIR/err" || got=$?
      if [ "$want" -eq "$got" ]; then
        printf '  ✓ %s\n' "$name"
      else
        printf '  ✗ %s: exited %s, expected %s\n' "$name" "$got" "$want" >&2
        status=1
      fi
    }
    # Input either guard does not understand: both fail open.
    shared_failopen() {
      expect_raw 0 "malformed input is allowed" 'not json'
      expect_raw 0 "input without a command is allowed" '{"tool_input": {}}'
      expect_raw 0 "an unterminated quote is allowed" \
        '{"tool_input": {"command": "cat \"unterminated; sleep 30"}}'
    }

    guard=claude-read-guard
    echo "$guard:"
    mkdir -p skills-store/big-skill/references "$HOME/.claude/skills"
    head -c 9000 /dev/zero >skills-store/big-skill/SKILL.md
    head -c 9000 /dev/zero >skills-store/big-skill/references/ref.md
    head -c 20000 /dev/zero >skills-store/big-skill/references/huge-ref.md
    ln -s "$dir/skills-store/big-skill" "$HOME/.claude/skills/big-skill"

    expect 2 "a single large file is blocked" "cat huge"
    expect 0 "a file under the limit is allowed" "cat big-a"
    expect 0 "small files read together are allowed" "cat small-a small-b"
    expect 2 "large files read together are blocked" "cat big-a big-b"
    grep -q "grep -n first" "$TMPDIR/err" || { echo "  ✗ the block carries the hint" >&2; status=1; }
    expect 2 "a glob naming large files is blocked" "cat big-*"
    expect 2 "large files across chained cats are blocked" "cat big-a && cat -n big-b"
    expect 2 "a large blob shown with another file is blocked" "git show HEAD:big-a; cat big-b"
    expect 2 "git -C sizes blobs in that repository" "cd / && git -C $dir show HEAD:big-a HEAD:big-a"
    expect 2 "cd to an absolute path moves later reads" "cd $dir/sub && cat big-c big-d"
    expect 2 "cd to a relative path moves later reads" "cd sub && cat -n big-c; cat big-d"
    expect 0 "small files after a relative cd are allowed" "cd sub && cat small-c small-d"
    expect 0 "a cd to a missing directory is allowed" "cd nowhere && cat big-a big-b"
    expect 0 "a commit without a path is not sized" "git show HEAD; cat big-b"
    expect 2 "missing files are skipped, the rest still count" "cat nope big-a big-b"
    expect 0 "other commands are allowed" "grep -n x big-a big-b huge"
    expect 0 "a heredoc write is allowed" "cat > out <<'EOF'
    big-a big-b
    EOF"
    expect 0 "large files redirected to a file are allowed" "cat big-a big-b > combined"
    expect 0 "large files appended to a file are allowed" "cat big-a big-b 2>/dev/null >> combined"
    expect 2 "a stderr redirect still shows stdout" "cat big-a big-b 2>/dev/null"
    expect 0 "a heredoc body naming large reads is allowed" "cat <<EOF > notes
    cat big-a big-b
    git show HEAD:big-a HEAD:big-a
    EOF
    echo done"
    expect 2 "reads after a heredoc body are still sized" "cat <<-EOF > notes
    body
    EOF
    cat big-a big-b"
    expect 0 "large files piped into a filter are allowed" "cat big-a big-b | grep -c x"
    expect 0 "a blob piped into a filter is allowed" "git show HEAD:big-a HEAD:big-a | head"

    expect 0 "large skill files read together are allowed" \
      "cat ~/.claude/skills/big-skill/SKILL.md ~/.claude/skills/big-skill/references/ref.md"
    expect 0 "a large skill reference is allowed" "cat ~/.claude/skills/big-skill/references/huge-ref.md"
    expect 0 "a skill glob is allowed" "cd ~/.claude/skills/big-skill && cat SKILL.md references/*"
    expect 2 "a skill file does not exempt another large file" \
      "cat ~/.claude/skills/big-skill/SKILL.md big-a big-b"
    expect 2 "a path that leaves the skills directory is sized" \
      "cat ~/.claude/skills/../../$(basename "$dir")/big-a big-b"

    mkdir -p repo-docs/skills/custom/foo/references repo-docs/skills/bar/references/deep repo-docs/notskills/bar
    for file in {,repo-docs/}{AGENTS,CLAUDE,SKILL,factory-instructions}.md NOTCLAUDE.md \
      repo-docs/skills/custom/foo/references/a.md \
      repo-docs/skills/default.nix repo-docs/notskills/bar/lib.py \
      repo-docs/skills/bar/{lib.py,references/{b.md,deep/nested.md}}; do
      head -c 9000 /dev/zero >"$file"
    done
    git add huge repo-docs
    git commit --quiet -m docs

    expect 0 "instruction files read together are allowed" \
      "cat AGENTS.md CLAUDE.md SKILL.md factory-instructions.md"
    expect 0 "instruction files are exempt by basename anywhere" "cat repo-docs/CLAUDE.md repo-docs/SKILL.md"
    expect 0 "skill references read together are allowed" \
      "cat repo-docs/skills/custom/foo/references/a.md repo-docs/skills/bar/references/*.md"
    expect 0 "a skill's source is allowed" "cat repo-docs/skills/bar/lib.py big-a"
    expect 0 "a nested skill file is allowed" "cat repo-docs/skills/bar/references/deep/nested.md big-a"
    expect 0 "instruction blobs read together are allowed" "git show HEAD:repo-docs/CLAUDE.md HEAD:repo-docs/SKILL.md"
    expect 0 "reference blobs read together are allowed" \
      "git -C $dir show HEAD:repo-docs/skills/custom/foo/references/a.md HEAD:repo-docs/skills/bar/references/b.md"
    expect 0 "an exempt file leaves a small sibling allowed" "cat CLAUDE.md big-a"
    mkdir admin
    head -c 9000 /dev/zero >admin/hm_CLAUDE.md
    ln -s hm_CLAUDE.md admin/CLAUDE.md
    expect 0 "an instruction file is exempt by the name it was read under" "cat admin/CLAUDE.md big-a"

    expect 2 "an exempt file does not exempt a source file over the limit" "cat CLAUDE.md huge"
    expect 2 "a single large blob is blocked" "git show HEAD:huge"
    expect 2 "an exempt blob does not exempt a blob over the limit" "git show HEAD:repo-docs/CLAUDE.md HEAD:huge"
    expect 2 "a skill file does not exempt a source file over the limit" "cat repo-docs/skills/bar/lib.py huge"
    expect 2 "a file directly under skills is counted" "cat repo-docs/skills/default.nix big-a"
    expect 2 "a directory that only ends in skills is counted" "cat repo-docs/notskills/bar/lib.py big-a"
    expect 2 "a name that only ends like an instruction file is counted" "cat NOTCLAUDE.md big-a"

    # Runs $guard on a Read of $3 with the extra tool input in $4.
    expect_read() {
      expect_raw "$1" "$2" "$(jq -n --arg p "$3" --arg d "$dir" --argjson i "''${4:-null}" \
        '{hook_event_name: "PreToolUse", tool_name: "Read", tool_input: ({file_path: $p} + $i), cwd: $d}')"
    }
    head -c 20000 /dev/zero >huge.png
    head -c 20000 /dev/zero >huge.PDF
    mkdir instructions
    head -c 20000 /dev/zero >instructions/CLAUDE.md

    expect_read 2 "a whole Read of a large file is blocked" "$dir/huge"
    grep -q "offset and limit" "$TMPDIR/err" || { echo "  ✗ the Read block carries the hint" >&2; status=1; }
    expect_read 2 "a relative Read resolves against cwd" huge
    expect_read 2 "an offset alone does not bound a Read" huge '{"offset": 100}'
    expect_read 2 "a Read that leaves a skill is sized" "$dir/repo-docs/skills/bar/../../../huge"
    expect_read 0 "a limited Read of a large file is allowed" "$dir/huge" '{"limit": 100}'
    expect_read 0 "a whole Read of a small file is allowed" "$dir/big-a"
    expect_read 0 "a Read of a large skill reference is allowed" \
      "$HOME/.claude/skills/big-skill/references/huge-ref.md"
    expect_read 0 "a Read of a large instruction file is allowed" "$dir/instructions/CLAUDE.md"
    expect_read 0 "a Read of an image is allowed" "$dir/huge.png"
    expect_read 0 "a Read of a PDF is allowed, in any case" "$dir/huge.PDF"
    expect_read 0 "a Read of a missing file is allowed" "$dir/nope"
    expect_raw 0 "a Read without a path is allowed" '{"tool_name": "Read", "tool_input": {}}'
    shared_failopen

    guard=claude-wait-guard
    echo "$guard:"
    expect 2 "a long sleep is blocked" "sleep 30"
    grep -q "run_in_background" "$TMPDIR/err" || { echo "  ✗ the block carries the hint" >&2; status=1; }
    expect 2 "a sleep with a unit is blocked" "sleep 1m"
    expect 2 "a long sleep after another command is blocked" "nix build && sleep 600; cat log"
    expect 2 "an until loop around a sleep is blocked" "until [ -f x ]; do sleep 5; done"
    expect 2 "a while loop around a sleep is blocked" "while pgrep foo; do sleep 2; done"
    expect 2 "a multi-line poll is blocked" "while true
    do
      sleep 1
    done"
    expect 2 "a sleep as a while condition is blocked" "while sleep 5; do curl x && break; done"
    expect 2 "a sleep as an until condition is blocked" "until sleep 3; do :; done"
    expect 2 "a long sleep as an if condition is blocked" "if sleep 30; then ls; fi"
    expect 0 "a short sleep is allowed" "sleep 2"
    expect 0 "a short sleep as an if condition is allowed" "if sleep 2; then ls; fi"
    expect 0 "a loop without a sleep is allowed" "while read l; do echo \"\$l\"; done < f"
    expect 0 "a sleep named in a string is allowed" "echo 'sleep 30' && git commit -m 'until done, sleep 60'"
    expect 0 "a heredoc body naming a sleep is allowed" "cat > s.sh <<'EOF'
    sleep 30
    EOF"
    expect_call 0 "a backgrounded long sleep is allowed" "sleep 30" true
    expect_call 0 "a backgrounded poll is allowed" "until [ -f x ]; do sleep 5; done" true

    expect 2 "a poll in bash -c is blocked" "bash -c 'until [ -f x ]; do sleep 5; done'"
    expect 2 "a poll in sh -c is blocked" "sh -c 'while pgrep foo; do sleep 2; done'"
    expect 2 "a long sleep in bash -c is blocked" "bash -c 'sleep 30'"
    expect 2 "a poll in bash -lc is blocked" "bash -lc 'until [ -f x ]; do sleep 5; done'"
    expect 2 "a poll in bash with options before -c is blocked" "bash -euo pipefail -c 'until [ -f x ]; do sleep 5; done'"
    expect 2 "a poll under timeout is blocked" "timeout 590 bash -c 'until [ -f x ]; do sleep 5; done'; cat log"
    expect 2 "a poll under nix develop is blocked" "nix develop .#ci -c bash -c 'until [ -f x ]; do sleep 5; done'"
    expect 2 "a poll under timeout and nix develop is blocked" "timeout 600 nix develop -c bash -c 'sleep 30'"
    expect 2 "a poll after an assignment is blocked" "D=/tmp bash -c 'until [ -f x ]; do sleep 5; done'"
    expect 2 "a long sleep under timeout is blocked" "timeout 60 sleep 30"
    expect 2 "a wait after a flake reference is blocked" "nix build .#foo; sleep 30"
    expect 2 "a wait after a flake reference in bash -c is blocked" "bash -c 'nix build .#foo; sleep 30'"
    expect 2 "a double-quoted bash -c keeps its flake reference apart" "bash -c \"nix build .#foo; sleep 30\""
    expect 2 "a nested bash -c keeps its flake reference apart" "bash -c \"bash -c 'nix build .#foo; sleep 30'\""
    expect 2 "an until around a bash -c condition is blocked" "until bash -c 'test -f x'; do sleep 5; done"
    expect 2 "a while around a wrapped condition is blocked" "while timeout 60 bash -c 'pgrep foo'; do sleep 2; done"
    expect 2 "tail -f is blocked" "tail -f build.log"
    expect 2 "tail -F is blocked" "tail -F build.log"
    expect 2 "tail --follow is blocked" "tail --follow build.log"
    expect 2 "tail --follow=name is blocked" "tail --follow=name build.log"
    expect 2 "tail with -f in a flag cluster is blocked" "tail -fn 20 build.log"
    expect 2 "tail -f piped into a filter is blocked" "tail -n +1 -f build.log | grep -m1 ^EXIT"
    expect 2 "tail -f on a pid is blocked" "tail --pid=\"\$P\" -f /dev/null"
    expect 2 "tail -f under timeout is blocked" "timeout 590 tail -n +1 -f build.log | grep -m1 done"
    expect 2 "tail -f in bash -c is blocked" "bash -c 'tail -f build.log'"
    expect 2 "tail -f before && is blocked" "tail -f build.log && just build"
    expect 2 "a wait after a backgrounded tail -f is blocked" "tail -f build.log & sleep 30"
    expect 2 "a bash -c script that does not parse keeps the outer verdict" "sleep 30; bash -c 'echo a\\'"
    expect 0 "a bash -c script that does not parse is allowed alone" "bash -c 'echo a\\'"
    expect 0 "a tail -f sent to the background with & is allowed" "tail -f build.log & just build; kill %1"
    expect 0 "a commented-out wait is allowed" "ls # sleep 30"
    expect 0 "a one-shot script in bash -c is allowed" "bash -c 'echo hi; ls'"
    expect 0 "a commented-out wait in bash -c is allowed" "bash -c 'ls # sleep 30'"
    expect 0 "a bash -c in a loop without a sleep is allowed" "while read l; do bash -c 'echo hi'; done < f"
    expect 0 "a short sleep after a bash -c condition is allowed" "if bash -c 'true'; then sleep 2; fi"
    expect 0 "a short sleep in bash -c is allowed" "bash -c 'sleep 2'"
    expect 0 "a build under nix develop is allowed" "nix develop -c bash -c 'just test'"
    expect 0 "a command under timeout is allowed" "timeout 600 just test"
    expect 0 "a short timeout bounds tail -f" "timeout 4 tail -f build.log"
    expect 0 "a short timeout bounds a poll" "timeout 5 bash -c 'until [ -f x ]; do sleep 1; done'"
    expect 0 "tail -n is allowed" "tail -n 20 build.log"
    expect 0 "tail -c is allowed" "tail -c 100 build.log"
    expect 0 "tail on a file named after the flag is allowed" "tail -n 5 -- f"
    expect 0 "a plain tail is allowed" "tail build.log"
    expect 0 "a tail in a pipe is allowed" "just test | tail -20"
    expect 0 "a -f on another command is allowed" "rm -f build.log; grep -f patterns log"
    expect 0 "a wrapper named in a string is allowed" "echo \"bash -c 'sleep 30'\" && git commit -m 'tail -f log'"
    expect_call 0 "a backgrounded tail -f is allowed" "tail -f build.log" true
    expect_call 0 "a backgrounded bash -c poll is allowed" "bash -c 'until [ -f x ]; do sleep 5; done'" true
    shared_failopen

    echo "claude-wait-guard, in a subagent:"
    session=$TMPDIR/session
    mkdir -p "$session/subagents"
    # An assistant line with one Bash call.
    bash_line() {
      jq -cn --arg c "$1" --arg i "$2" \
        '{type: "assistant", message: {id: $i, content: [{type: "tool_use", id: $i, name: "Bash", input: {command: $c}}]}}'
    }
    # Runs the guard on a Bash call in subagent $agent, or in main with agent=.
    expect_agent() {
      local want="$1" name="$2" command="$3" background="''${4:-false}"
      expect_raw "$want" "$name" "$(jq -n --arg c "$command" --arg a "$agent" --arg t "$session.jsonl" --argjson b "$background" \
        '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_use_id: "now", transcript_path: $t,
          tool_input: {command: $c, run_in_background: $b}} + (if $a == "" then {} else {agent_id: $a} end)')"
    }
    agent=polled
    bash_line "gh pr checks 7" old >"$session/subagents/agent-polled.jsonl"
    bash_line "gh pr checks 7" now >>"$session/subagents/agent-polled.jsonl"
    expect_agent 2 "a second read of the same checks is blocked" "gh pr checks 7"
    grep -q "never waits on CI" "$TMPDIR/err" || { echo "  ✗ the block carries the CI hint" >&2; status=1; }
    expect_agent 2 "a second read with other flags is blocked" "gh pr checks 7 --json state"
    expect_agent 0 "another pull request's checks are allowed" "gh pr checks 8"
    expect_agent 0 "a repeated command that is not CI is allowed" "git status"
    agent=fresh
    bash_line "gh pr checks 7" now >"$session/subagents/agent-fresh.jsonl"
    expect_agent 0 "a first read is allowed, though the transcript holds the call itself" "gh pr checks 7"
    expect_agent 0 "a log read is allowed" "gh run view 12 --log-failed | rg error"
    expect_agent 0 "a one-shot run status is allowed" "gh run view 12"
    expect_agent 2 "gh pr checks --watch is blocked" "gh pr checks 7 --watch"
    expect_agent 2 "gh pr checks --watch in the background is blocked" "gh pr checks 7 --watch" true
    expect_agent 2 "gh run watch is blocked" "gh run watch 12"
    expect_agent 2 "gh run watch under timeout is blocked" "timeout 300 gh run watch 12"
    expect_agent 2 "gh run watch in nix develop is blocked" "nix develop -c bash -c 'gh run watch 12'"
    expect_agent 2 "a polling loop in the background is blocked" "until gh pr checks 7; do sleep 30; done" true
    expect_agent 2 "a for loop over a read is blocked" "for i in 1 2 3; do gh run view 12; sleep 30; done" true
    expect_agent 2 "a log read in a loop is blocked" "while true; do gh run view 12 --log; done" true
    expect_agent 2 "two reads in one command are blocked" "gh pr checks 7; sleep 5; gh pr checks 7"
    expect_agent 0 "reads of two pull requests in one command are allowed" "gh pr checks 7; gh pr checks 8"
    agent=missing
    expect_agent 0 "a subagent with no transcript yet may read once" "gh pr checks 7"
    expect_agent 2 "a subagent with no transcript still may not watch" "gh run watch 12"
    expect_agent 2 "a subagent with no transcript still may not loop" "until gh pr checks 7; do sleep 30; done" true
    agent=
    bash_line "gh pr checks 7" old >"$session.jsonl"
    expect_agent 0 "main may read checks again" "gh pr checks 7"
    expect_agent 0 "main may watch in the background" "gh pr checks 7 --watch" true
    expect_agent 0 "main may run gh run watch" "gh run watch 12"

    guard=claude-context-guard
    echo "$guard:"
    # An assistant line of a call that sent $2 input and $3 cache read tokens.
    usage_line() {
      jq -cn --arg i "$1" --argjson n "$2" --argjson r "$3" \
        '{type: "assistant", message: {id: $i, usage: {input_tokens: $n, cache_read_input_tokens: $r, cache_creation_input_tokens: 500}}}'
    }
    # Runs the guard on the transcript of $agent and checks what it prints: text
    # holding $1, or nothing for an empty $1.
    expect_notice() {
      local want="$1" name="$2" input got
      input=$(jq -n --arg t "$session.jsonl" --arg a "$agent" \
        '{hook_event_name: "PostToolUse", tool_name: "Bash", transcript_path: $t} + (if $a == "" then {} else {agent_id: $a} end)')
      got=$(printf '%s' "$input" | "$guard" | jq -r .hookSpecificOutput.additionalContext)
      if { [ -z "$want" ] && [ -z "$got" ]; } || { [ -n "$want" ] && [[ "$got" == *"$want"* ]]; }; then
        printf '  ✓ %s\n' "$name"
      else
        printf '  ✗ %s: printed "%s"\n' "$name" "$got" >&2
        status=1
      fi
    }
    agent=
    file=$session.jsonl
    { usage_line a 100 1000; usage_line b 100 2000; } >"$file"
    expect_notice "" "under the budget it says nothing"
    { usage_line a 100 148000; usage_line b 100 150000; } >"$file"
    expect_notice "Context 150k" "crossing 150k warns"
    { usage_line a 100 150000; usage_line b 100 151000; } >"$file"
    expect_notice "" "staying past 150k says nothing"
    { usage_line a 100 218000; usage_line b 100 220000; } >"$file"
    expect_notice "stop now" "crossing 220k says stop"
    { usage_line a 100 220000; usage_line b 100 221000; } >"$file"
    expect_notice "" "staying past 220k says nothing"
    { usage_line a 100 228000; usage_line b 100 230000; } >"$file"
    expect_notice "stop now" "another 10k past the budget says stop again"
    { usage_line a 100 230000; usage_line b 100 90000; } >"$file"
    expect_notice "" "a compacted context says nothing"
    { usage_line a 100 148000; usage_line b 100 150000; usage_line b 100 150000; } >"$file"
    expect_notice "Context 150k" "a message of several lines counts as one call"
    { usage_line a 100 150000; usage_line b 100 150000; usage_line c 0 0 | sed 's/500/0/'; } >"$file"
    expect_notice "" "an empty synthetic call is skipped"
    usage_line b 100 150000 >"$file"
    expect_notice "Context 150k" "a first call past the line warns"
    { usage_line a 100 148000; usage_line b 100 150000; echo '{"type":"assis'; } >"$file"
    expect_notice "Context 150k" "a partial last line is skipped"
    agent=deep
    { usage_line a 100 1000; usage_line b 100 1000; } >"$file"
    { usage_line a 100 148000; usage_line b 100 150000; } >"$session/subagents/agent-deep.jsonl"
    expect_notice "Context 150k" "a subagent is judged on its own transcript"
    { usage_line a 100 148000; usage_line b 100 150000; } >"$file"
    { usage_line a 100 1000; usage_line b 100 1000; } >"$session/subagents/agent-deep.jsonl"
    expect_notice "" "a subagent is not judged on the parent's transcript"
    agent=gone
    expect_notice "" "a missing transcript says nothing"
    expect_raw 0 "malformed input is allowed" 'not json'
    expect_raw 0 "input without a transcript is allowed" '{"tool_input": {}}'

    guard=$TMPDIR/secret-guard
    echo "claude-secret-guard:"
    printf '#!${pkgs.runtimeShell}\nexec claude-secret-guard %s\n' \
      "'{\"paths\": [\"/run/secrets/qa-key\"], \"vars\": [\"QA_KEY_FILE\"]}'" >"$guard"
    chmod +x "$guard"
    expect 2 "reading the path is blocked" "cat /run/secrets/qa-key"
    grep -q "Never read it from a shell" "$TMPDIR/err" || { echo "  ✗ the block carries the hint" >&2; status=1; }
    expect 2 "expanding the variable is blocked" 'cat "$QA_KEY_FILE"'
    expect 2 "a braced expansion is blocked" 'xxd ''${QA_KEY_FILE:-x}'
    expect 2 "a heredoc script naming the path is blocked" "python3 - <<'EOF'
    print(open('/run/secrets/qa-key').read())
    EOF"
    expect 2 "the variable printed into a substitution is blocked" 'cat $(printenv QA_KEY_FILE)'
    expect 2 "the variable printed into backticks is blocked" 'xxd `printenv QA_KEY_FILE`'
    expect 2 "an env dump in a substitution is blocked" 'cat $(env | sed -n s/QA_KEY_FILE=//p)'
    expect 2 "a glob over the secrets directory is blocked" "cat /run/secrets/qa-*"
    expect 2 "changing into the secrets directory is blocked" "cd /run/secrets && ls"
    expect 2 "the resolved secrets.d path is blocked" "cat /run/secrets.d/5/qa-key"
    expect 2 "the basename alone is blocked" "cd /tmp/x && cat qa-key"
    expect 0 "naming the variable without expanding it is allowed" "printenv QA_KEY_FILE"
    expect 0 "the availability check is allowed" "printenv QA_KEY_FILE >/dev/null"
    expect 0 "a longer variable name is allowed" 'echo "$QA_KEY_FILE_HINT"'
    expect 0 "a longer basename is allowed" "cat qa-key-notes.md"
    expect 0 "a substitution running another command is allowed" 'echo $(environment-check) `git rev-parse HEAD`'
    expect 0 "running a script that reads the variable itself is allowed" "qa-node wallet.cjs"
    expect 0 "running a qa-node script by file is allowed" "qa-node script.cjs"
    shared_failopen

    if [ "$status" -ne 0 ]; then
      echo "claude-bash-guards: a hook decides wrongly" >&2
      exit 1
    fi
    touch "$out"
  ''
