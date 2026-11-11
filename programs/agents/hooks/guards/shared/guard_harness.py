"""What the guard tests share: a built guard, run the way the dispatcher runs a hook.

The guards are black box here. A test feeds a neutral event (agent_hook.py) to
the real executable the check built, and asserts on the verdict it prints, so
packaging stays covered. Cases are plain tables, `(want, name, given)`, for a
corpus to extend.
"""

import os
import stat
import subprocess
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

import pytest
from agent_hook import (
    AfterTool,
    Agent,
    AgentId,
    Allow,
    BeforeTool,
    ContextSize,
    Deny,
    JsonObject,
    Note,
    Role,
    SessionId,
    Tool,
    Verdict,
    emit_event,
    parse_note,
    parse_verdict,
)

type Decision = Literal["allow", "deny"]
ALLOWED: Decision = "allow"
BLOCKED: Decision = "deny"

type Case[T, W = Decision] = tuple[W, str, T]

SESSION = SessionId("s1")
SUBAGENT = Agent(AgentId("a1b2"), Role("implementer"))


def shell_event(
    command: str,
    *,
    background: bool = False,
    cwd: str = "/",
    agent: Agent | None = None,
    history: Sequence[str] = (),
) -> str:
    """The event a guard gets for a shell call."""
    tool_input: JsonObject = {"command": command, "run_in_background": background}
    return tool_event(Tool.SHELL, tool_input, cwd=cwd, agent=agent, history=history)


def tool_event(
    tool: Tool,
    tool_input: JsonObject,
    *,
    cwd: str = "/",
    agent: Agent | None = None,
    history: Sequence[str] = (),
) -> str:
    """The beforeTool event a guard gets for a call of `tool`."""
    return emit_event(
        BeforeTool(SESSION, Path(cwd), agent, tool, tool_input, tuple(history))
    )


def after_tool_event(context: ContextSize | None) -> str:
    """The afterTool event of a shell call, with the context it reports."""
    return emit_event(
        AfterTool(SESSION, Path("/"), None, Tool.SHELL, {"command": "ls"}, "", context)
    )


# Input no guard understands: every shell guard fails open on it.
FAIL_OPEN_CASES: list[Case[str]] = [
    (ALLOWED, "malformed input is allowed", "not json"),
    (
        ALLOWED,
        "a shell call without a command is allowed",
        tool_event(Tool.SHELL, {}),
    ),
    (
        ALLOWED,
        "an unterminated quote is allowed",
        shell_event('cat "unterminated; sleep 30'),
    ),
]

# A guard's source on another shfmt: a built one holds its store path for good.
# The guard imports its shared modules from beside this file, the contract
# from the hooks directory above.
ON_SHFMT = """
import runpy, sys
shared, contract, guard, shfmt, timeout = sys.argv[1:]
sys.path[:0] = [shared, contract]
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


def guard_on(source: Path, shfmt: str, timeout_seconds: float = 2) -> list[str]:
    """Argv for the guard source `source`, parsing with `shfmt`."""
    here = Path(__file__)
    shared, contract = str(here.parent), str(here.parents[2])
    python = os.environ["STDLIB_PYTHON"]
    return [
        python,
        "-c",
        ON_SHFMT,
        shared,
        contract,
        str(source),
        shfmt,
        str(timeout_seconds),
    ]


def guard_on_broken(source: Path, broken: BrokenShfmt, directory: Path) -> list[str]:
    match broken:
        case MissingShfmt():
            return guard_on(source, str(directory / "missing"))
        case FakeShfmt(fake, timeout_seconds):
            return guard_on(source, fake_shfmt(directory, fake), timeout_seconds)


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


def judge(argv: list[str], event: str, env: Mapping[str, str] = os.environ) -> Verdict:
    """What a beforeTool guard decides. A guard always exits 0 and never writes
    to stderr: failing open is printing nothing."""
    return parse_verdict(run_guard(argv, event, env))


def observe(argv: list[str], event: str) -> Note:
    """What an afterTool guard says."""
    return parse_note(run_guard(argv, event, os.environ))


def decision(verdict: Verdict) -> Decision:
    match verdict:
        case Allow():
            return ALLOWED
        case Deny():
            return BLOCKED


def reason(verdict: Verdict) -> str:
    """A deny's reason; an allow fails the test."""
    match verdict:
        case Deny(reason=told):
            return told
        case Allow():
            pytest.fail("the call was allowed")


def run_guard(argv: list[str], event: str, env: Mapping[str, str]) -> str:
    done = subprocess.run(
        argv, input=event, capture_output=True, text=True, check=False, env=env
    )
    if (done.returncode, done.stderr) != (0, ""):
        pytest.fail(f"the guard exited {done.returncode}: {done.stderr}")
    return done.stdout
