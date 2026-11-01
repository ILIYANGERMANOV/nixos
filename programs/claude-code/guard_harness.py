"""What the guard tests share: a built guard, run the way Claude Code runs a hook.

The guards are black box here. A test feeds real JSON to the real executable the
check built, and asserts on its exit code and output, so packaging stays covered.
Cases are plain tables, `(want, name, given)`, for a corpus to extend.
"""

import json
import os
import stat
import subprocess
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

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

# A guard's source on another shfmt: a built one holds its store path for good.
ON_SHFMT = """
import pathlib, runpy, sys
guard, shfmt, timeout = sys.argv[1:]
sys.path.insert(0, str(pathlib.Path(guard).parent))
import bash_commands
bash_commands.SHFMT = shfmt
bash_commands.SHFMT_TIMEOUT_SECONDS = float(timeout)
runpy.run_path(guard, run_name="__main__")
"""


@dataclass(frozen=True)
class MissingShfmt:
    pass


@dataclass(frozen=True)
class FakeShfmt:
    script: str
    timeout_seconds: float = 2


type BrokenShfmt = MissingShfmt | FakeShfmt


# A real timeout would cost 2 s a call. Short, a hang still always exceeds it.
BROKEN_SHFMT: list[Case[BrokenShfmt]] = [
    (ALLOWED, "a missing shfmt allows the call", MissingShfmt()),
    (ALLOWED, "a crashing shfmt allows the call", FakeShfmt("exit 3")),
    (
        ALLOWED,
        "a hanging shfmt allows the call",
        FakeShfmt("exec sleep 30", timeout_seconds=0.05),
    ),
    (ALLOWED, "shfmt printing no JSON allows the call", FakeShfmt("echo not json")),
    (
        ALLOWED,
        "a renamed shfmt field allows the call",
        FakeShfmt("""echo '{"Stmts": [{"Cmd": {"Kind": "CallExpr"}}]}'"""),
    ),
]


def guard_on(script: str, shfmt: str, timeout_seconds: float = 2) -> list[str]:
    """Argv for the guard source beside this file, parsing with `shfmt`."""
    source = Path(__file__).with_name(script)
    python = os.environ["STDLIB_PYTHON"]
    return [python, "-c", ON_SHFMT, str(source), shfmt, str(timeout_seconds)]


def guard_on_broken(script: str, broken: BrokenShfmt, directory: Path) -> list[str]:
    match broken:
        case MissingShfmt():
            return guard_on(script, str(directory / "missing"))
        case FakeShfmt(fake, timeout_seconds):
            return guard_on(script, fake_shfmt(directory, fake), timeout_seconds)


def fake_shfmt(directory: Path, script: str) -> str:
    """An executable to stand in for shfmt, for what the real one will not do."""
    fake = directory / "shfmt"
    _ = fake.write_text(f"#!/bin/sh\n{script}\n")
    fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
    return str(fake)


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
    tool_input = {"command": command, "run_in_background": background}
    return tool_event("Bash", tool_input, **fields)


def tool_event(tool: str, tool_input: Mapping[str, object], **fields: str) -> str:
    """The JSON Claude Code sends a PreToolUse hook."""
    event: dict[str, object] = {
        "hook_event_name": "PreToolUse",
        "tool_name": tool,
        "tool_input": tool_input,
    }
    return json.dumps(event | fields)


def agent_fields(agent: str | None) -> dict[str, str]:
    """What a hook event adds for a subagent. `None` is the main agent."""
    return {} if agent is None else {"agent_id": agent}


def session_with(root: Path, main: str, subagents: Mapping[str, str]) -> Path:
    """Writes the transcripts in Claude Code's layout. Returns the main one."""
    (root / "session/subagents").mkdir(parents=True)
    for agent, lines in subagents.items():
        _ = (root / f"session/subagents/agent-{agent}.jsonl").write_text(lines)
    path = root / "session.jsonl"
    _ = path.write_text(main)
    return path
