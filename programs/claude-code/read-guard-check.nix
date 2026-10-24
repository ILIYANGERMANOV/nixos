# checks.claude-read-guard: the read-guard hook against real files and a real
# git repository, fed the same JSON Claude Code sends a PreToolUse hook.
# Exit 2 blocks the call; exit 0 allows it.
{ pkgs }:

let
  guard = (import ./read-guard.nix { inherit pkgs; }).bin;
in
pkgs.runCommand "claude-read-guard-check"
  {
    nativeBuildInputs = [
      guard
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

    # Runs the hook on a Bash command and checks its exit code.
    expect() {
      local want="$1" name="$2" command="$3"
      expect_raw "$want" "$name" "$(jq -n --arg c "$command" --arg d "$dir" \
        '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}, cwd: $d}')"
    }
    # Runs the hook on raw input and checks its exit code.
    expect_raw() {
      local want="$1" name="$2" input="$3" got=0
      printf '%s' "$input" | claude-read-guard 2>"$TMPDIR/err" || got=$?
      if [ "$want" -eq "$got" ]; then
        printf '  ✓ %s\n' "$name"
      else
        printf '  ✗ %s: exited %s, expected %s\n' "$name" "$got" "$want" >&2
        status=1
      fi
    }

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

    expect_raw 0 "malformed input is allowed" 'not json'
    expect_raw 0 "input without a command is allowed" '{"tool_input": {}}'
    expect_raw 0 "an unterminated quote is allowed" \
      '{"tool_input": {"command": "cat \"unterminated"}}'

    if [ "$status" -ne 0 ]; then
      echo "claude-read-guard: the hook decides wrongly" >&2
      exit 1
    fi
    touch "$out"
  ''
