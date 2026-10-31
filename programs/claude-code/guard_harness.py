"""What the guard tests share: a built guard, run the way Claude Code runs a hook.

The guards are black box here. A test feeds real JSON to the real executable the
check built, and asserts on its exit code and output, so packaging stays covered.
Cases are plain tables, `(want, name, given)`, for a corpus to extend.
"""

import json
import os
import subprocess
from collections.abc import Mapping

import pytest

# How Claude Code reads a hook's exit code.
ALLOWED = 0
BLOCKED = 2

type Case[T, W = int] = tuple[W, str, T]

# Input no guard understands: every Bash guard fails open on it.
FAIL_OPEN_CASES: list[Case[str]] = [
    (ALLOWED, "malformed input is allowed", "not json"),
    (ALLOWED, "input without a command is allowed", '{"tool_input": {}}'),
    (
        ALLOWED,
        "an unterminated quote is allowed",
        '{"tool_input": {"command": "cat \\"unterminated; sleep 30"}}',
    ),
]


def guard_cases[T, W](rows: list[Case[T, W]]) -> pytest.MarkDecorator:
    """One test per row, named after its behaviour, taking `want` and `given`."""
    return pytest.mark.parametrize(
        ("want", "given"),
        [(want, given) for want, _, given in rows],
        ids=[name for _, name, _ in rows],
    )


def run_guard(
    argv: list[str], event: str, env: Mapping[str, str] = os.environ
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        argv, input=event, capture_output=True, text=True, check=False, env=env
    )


def bash_event(command: str, *, background: bool = False, **fields: str) -> str:
    """The JSON Claude Code sends a PreToolUse hook for a Bash call."""
    return json.dumps(
        {
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": command, "run_in_background": background},
        }
        | fields
    )
