"""The envelopes plugin/kategory.js sends agent-hook-opencode, built as the
plugin builds them: every test of the adapter draws on these. They carry
OpenCode 1.19.5's own hook input and output (packages/opencode/src/session/
tools.ts, session/prompt.ts, tool/*.ts)."""

from collections.abc import Sequence
from pathlib import Path

from agent_hook import Json, JsonObject

LEAD = "ses_lead"
CHILD = "ses_child"
CWD = Path("/work/repo")
CALL = "call_1"


def envelope(hook: str, directory: Path = CWD, **fields: Json) -> JsonObject:
    """The lead's envelope: its session is its own root."""
    common: JsonObject = {
        "hook": hook,
        "sessionID": LEAD,
        "rootID": LEAD,
        "agent": "build",
        "directory": str(directory),
    }
    return common | fields


def in_child(payload: JsonObject, agent: Json = "implementer") -> JsonObject:
    return payload | {"sessionID": CHILD, "agent": agent}


def before(
    tool: str,
    args: JsonObject,
    history: Sequence[str] = (),
    directory: Path = CWD,
    call: str = CALL,
) -> JsonObject:
    return envelope(
        "before", directory, tool=tool, args=args, callID=call, history=[*history]
    )


def after(  # noqa: PLR0913 - one parameter per envelope field
    tool: str,
    args: JsonObject,
    output: str,
    tokens: Sequence[Json] = (),
    running: Sequence[str] = (),
    directory: Path = CWD,
    call: str = CALL,
    spent: JsonObject | None = None,
) -> JsonObject:
    ran: JsonObject = {"title": "t", "output": output, "metadata": {}}
    return envelope(
        "after",
        directory,
        tool=tool,
        args=args,
        callID=call,
        output=ran,
        tokens=[*tokens],
        running=[*running],
        spent={} if spent is None else spent,
    )


def call_tokens(
    sent: int, read: int = 0, write: int = 0, output: int = 0, reasoning: int = 0
) -> JsonObject:
    """A model call's `tokens`, as message.updated tells them; a child's
    `spent` has the same shape."""
    return {
        "input": sent,
        "output": output,
        "reasoning": reasoning,
        "cache": {"read": read, "write": write},
    }


def task_output(
    state: str, text: str, summary: str | None = None, child: str = CHILD
) -> str:
    """tool/task.ts renderOutput: a failed task's text is a task_error."""
    tag = "task_error" if state == "error" else "task_result"
    lines = [f'<task id="{child}" state="{state}">']
    lines += [] if summary is None else [f"<summary>{summary}</summary>"]
    return "\n".join([*lines, f"<{tag}>", text, f"</{tag}>", "</task>"])
