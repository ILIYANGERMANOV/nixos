"""The secret guard, built into a hook for one protected file."""

import json
import os

from guard_harness import (
    ALLOWED,
    BLOCKED,
    FAIL_OPEN_CASES,
    Case,
    bash_event,
    guard_cases,
    run_guard,
)

GUARD = [
    os.environ["SECRET_GUARD"],
    json.dumps({"paths": ["/run/secrets/qa-key"], "vars": ["QA_KEY_FILE"]}),
]

BASH_CASES: list[Case[str]] = [
    (BLOCKED, "reading the path is blocked", "cat /run/secrets/qa-key"),
    (BLOCKED, "expanding the variable is blocked", 'cat "$QA_KEY_FILE"'),
    (BLOCKED, "a braced expansion is blocked", "xxd ${QA_KEY_FILE:-x}"),
    (
        BLOCKED,
        "a heredoc script naming the path is blocked",
        "python3 - <<'EOF'\nprint(open('/run/secrets/qa-key').read())\nEOF",
    ),
    (
        BLOCKED,
        "the variable printed into a substitution is blocked",
        "cat $(printenv QA_KEY_FILE)",
    ),
    (
        BLOCKED,
        "the variable printed into backticks is blocked",
        "xxd `printenv QA_KEY_FILE`",
    ),
    (
        BLOCKED,
        "an env dump in a substitution is blocked",
        "cat $(env | sed -n s/QA_KEY_FILE=//p)",
    ),
    (BLOCKED, "a glob over the secrets directory is blocked", "cat /run/secrets/qa-*"),
    (
        BLOCKED,
        "changing into the secrets directory is blocked",
        "cd /run/secrets && ls",
    ),
    (BLOCKED, "the resolved secrets.d path is blocked", "cat /run/secrets.d/5/qa-key"),
    (BLOCKED, "the basename alone is blocked", "cd /tmp/x && cat qa-key"),
    (
        ALLOWED,
        "naming the variable without expanding it is allowed",
        "printenv QA_KEY_FILE",
    ),
    (ALLOWED, "the availability check is allowed", "printenv QA_KEY_FILE >/dev/null"),
    (ALLOWED, "a longer variable name is allowed", 'echo "$QA_KEY_FILE_HINT"'),
    (ALLOWED, "a longer basename is allowed", "cat qa-key-notes.md"),
    (
        ALLOWED,
        "a substitution running another command is allowed",
        "echo $(environment-check) `git rev-parse HEAD`",
    ),
    (
        ALLOWED,
        "running a script that reads the variable itself is allowed",
        "qa-node wallet.cjs",
    ),
    (ALLOWED, "running a qa-node script by file is allowed", "qa-node script.cjs"),
]


@guard_cases(BASH_CASES)
def test_bash_call(want: int, given: str) -> None:
    assert run_guard(GUARD, bash_event(given)).returncode == want


@guard_cases(FAIL_OPEN_CASES)
def test_raw_input(want: int, given: str) -> None:
    assert run_guard(GUARD, given).returncode == want


def test_a_block_carries_the_hint() -> None:
    result = run_guard(GUARD, bash_event("cat /run/secrets/qa-key"))

    assert result.returncode == BLOCKED
    assert "Never read it from a shell" in result.stderr
