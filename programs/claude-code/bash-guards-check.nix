# checks.claude-bash-guards: the PreToolUse Bash guards fed the same JSON
# Claude Code sends a hook, the read guard against real files and a real git
# repository. Exit 2 blocks the call; exit 0 allows it.
{ pkgs }:

pkgs.runCommand "claude-bash-guards-check"
  {
    nativeBuildInputs = [
      (import ./read-guard.nix { inherit pkgs; }).bin
      (import ./wait-guard.nix { inherit pkgs; }).bin
      (import ./secret-guard.nix { inherit pkgs; }).bin
      pkgs.git
      pkgs.jq
    ];
  }
  ''
    status=0
    dir=$TMPDIR/work
    mkdir -p "$dir"
    cd "$dir"
    head -c 6000 /dev/zero >big-a
    head -c 6000 /dev/zero >big-b
    head -c 20000 /dev/zero >huge
    echo small >small-a
    echo small >small-b
    mkdir sub
    head -c 6000 /dev/zero >sub/big-c
    head -c 6000 /dev/zero >sub/big-d
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
    head -c 6000 /dev/zero >skills-store/big-skill/SKILL.md
    head -c 6000 /dev/zero >skills-store/big-skill/references/ref.md
    ln -s "$dir/skills-store/big-skill" "$HOME/.claude/skills/big-skill"

    expect 0 "a single large file is allowed" "cat huge"
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
    expect 0 "missing files are not counted" "cat nope-a nope-b huge"
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
    expect 0 "a skill glob is allowed" "cd ~/.claude/skills/big-skill && cat SKILL.md references/*"
    expect 2 "a skill file does not exempt another large file" \
      "cat ~/.claude/skills/big-skill/SKILL.md big-a big-b"
    expect 2 "a path that leaves the skills directory is sized" \
      "cat ~/.claude/skills/../../$(basename "$dir")/big-a big-b"
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
    shared_failopen

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
    expect 0 "naming the variable without expanding it is allowed" "printenv QA_KEY_FILE"
    expect 0 "a longer variable name is allowed" 'echo "$QA_KEY_FILE_HINT"'
    expect 0 "running a script that reads the variable itself is allowed" "qa-node wallet.cjs"
    shared_failopen

    if [ "$status" -ne 0 ]; then
      echo "claude-bash-guards: a hook decides wrongly" >&2
      exit 1
    fi
    touch "$out"
  ''
