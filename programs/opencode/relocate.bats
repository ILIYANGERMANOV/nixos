#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2312 # the ~/.claude paths are text in the files, not expansions, and a masked failure fails the assertion around it

load ../shell-check/test_helper

setup() {
  export WORK="$BATS_TEST_TMPDIR"
  tree="$WORK/tree" out="$WORK/out"
  mkdir -p "$tree/skills/a/scripts" "$tree/agents"
}

relocate() {
  bash "$BATS_TEST_DIRNAME/relocate.sh" "$tree" "$out"
}

@test "every known form of a ~/.claude path names the output dir" {
  printf '%s\n' 'read `~/.claude/skills/x/SKILL.md`' 'cat $HOME/.claude/agents/y.md' >"$tree/skills/a/SKILL.md"
  echo 'root = Path.home() / ".claude" / "projects"' >"$tree/skills/a/scripts/analyze.py"

  relocate

  [ "$(cat "$out/skills/a/SKILL.md")" = "read \`$out/skills/x/SKILL.md\`
cat $out/agents/y.md" ]
  [ "$(cat "$out/skills/a/scripts/analyze.py")" = "root = Path(\"$out\") / \"projects\"" ]
}

@test "a skill's own dir variable names that skill's folder in the output" {
  echo 'read ${CLAUDE_SKILL_DIR}/references/x.md' >"$tree/skills/a/SKILL.md"
  mkdir -p "$tree/skills/b"
  echo 'python3 ${CLAUDE_SKILL_DIR}/scripts/y.py' >"$tree/skills/b/SKILL.md"

  relocate

  [ "$(cat "$out/skills/a/SKILL.md")" = "read $out/skills/a/references/x.md" ]
  [ "$(cat "$out/skills/b/SKILL.md")" = "python3 $out/skills/b/scripts/y.py" ]
}

@test "the skill dir variable outside a skill fails" {
  echo 'read ${CLAUDE_SKILL_DIR}/x.md' >"$tree/agents/r.md"

  run relocate

  [ "$status" -eq 1 ]
  [[ "$output" == *'CLAUDE_SKILL_DIR'*'still name ~/.claude'* ]]
}

@test "a project's own .claude and ~/.claude.json are left as they are" {
  echo 'see .claude/rules/x.md and ~/.claude.json' >"$tree/skills/a/SKILL.md"

  relocate

  [ "$(cat "$out/skills/a/SKILL.md")" = 'see .claude/rules/x.md and ~/.claude.json' ]
}

@test "links are resolved into a writable copy that keeps the executable bit" {
  echo 'echo hi' >"$WORK/run.sh"
  chmod 555 "$WORK/run.sh"
  ln -s "$WORK/run.sh" "$tree/skills/a/scripts/run.sh"

  relocate

  [ ! -L "$out/skills/a/scripts/run.sh" ]
  [ -x "$out/skills/a/scripts/run.sh" ]
  [ -w "$out/skills/a/scripts/run.sh" ]
}

@test "a form the rewrite does not know fails" {
  echo 'cat ${HOME}/.claude/skills/x/SKILL.md' >"$tree/skills/a/SKILL.md"

  run relocate

  [ "$status" -eq 1 ]
  [[ "$output" == *'${HOME}/.claude/skills'*'still name ~/.claude'* ]]
}

@test "a tree with no skills and no ~/.claude path is copied as it is" {
  rm -r "$tree/skills"
  echo plain >"$tree/agents/r.md"

  relocate

  [ "$(cat "$out/agents/r.md")" = plain ]
}

@test "a link that leads nowhere fails" {
  ln -s "$WORK/missing" "$tree/skills/a/scripts/run.sh"

  run relocate

  [ "$status" -ne 0 ]
}

@test "a search that cannot run fails instead of passing" {
  echo plain >"$tree/skills/a/SKILL.md"
  stub grep 'exit 2'

  run relocate

  [ "$status" -eq 2 ]
  [[ "$output" == *'relocate: could not search'* ]]
}
