"""PostToolUse hook: tell an agent its context is past the budget.

Reads the hook input from stdin and the agent's own transcript, whose assistant
lines carry the context each call sent. It compares the newest call with the
last one before it that ran a tool, the last the hook saw, so it needs no state,
loses no crossing on a text-only reply, and speaks only when the context crosses
a line: once at WARN_AT, at STOP_AT, then every STOP_STEP past it.
Calls sent together share a message and may each repeat the notice. The hook
only talks: blocking tools here would also block the commit and the push the notice asks
for. Everything else, including any input this script does not understand,
prints nothing and exits 0: the guard fails open.
"""

import json
import os
import sys
from pathlib import Path

from hook_event import Json, parse_caller, parse_json
from transcripts import own_transcript, parse_line

WARN_AT = 150_000
STOP_AT = 220_000
STOP_STEP = 10_000
# Enough for two calls unless a single result is larger, which only costs the
# comparison: the newest call then counts as a crossing.
TAIL_BYTES = 256 * 1024
WARN = (
    "Context {size}k, budget {stop}k: stop there. Until then, never run a check "
    "over about 4 minutes yourself: commit, push and hand back naming it."
)
STOP = (
    "Context {size}k, over the {stop}k budget: stop now. Commit, push, hand back "
    "a short note (files, decisions, what remains, how to verify); a fresh agent "
    "continues."
)


def main() -> None:
    try:
        event = parse_json(sys.stdin.read())
        contexts = recent_contexts(own_transcript(parse_caller(event)))
    except Exception:  # noqa: BLE001 - any failure must let the call through
        sys.exit(0)

    match contexts:
        case [current, previous, *_]:
            message = notice(previous, current)
        case [current]:
            message = notice(0, current)
        case _:
            message = None
    if message is not None:
        print(json.dumps(output(message)))


def recent_contexts(path: Path) -> list[int]:
    """The newest call's context, then each older one that ran a tool, newest first.

    One message spans a line per content block, each with the same usage.
    """
    contexts: dict[str, int] = {}
    ran_tool: set[str] = set()
    for line in reversed(tail_lines(path)):
        match parse_line(line):
            case {
                "type": "assistant",
                "message": {"id": str(message_id), "usage": dict(usage)} as message,
            } if context(usage) > 0:
                _ = contexts.setdefault(message_id, context(usage))
                if runs_tool(message):
                    ran_tool.add(message_id)
            case _:
                pass
    newest, older = list(contexts)[:1], list(contexts)[1:]
    return [contexts[call] for call in newest + [c for c in older if c in ran_tool]]


def runs_tool(message: dict[str, Json]) -> bool:
    match message:
        case {"content": list(blocks)}:
            return any(is_tool_use(block) for block in blocks)
        case _:
            return False


def is_tool_use(block: Json) -> bool:
    match block:
        case {"type": "tool_use"}:
            return True
        case _:
            return False


def tail_lines(path: Path) -> list[bytes]:
    with path.open("rb") as file:
        _ = file.seek(0, os.SEEK_END)
        _ = file.seek(max(0, file.tell() - TAIL_BYTES))
        return file.read().splitlines()


def context(usage: dict[str, Json]) -> int:
    return sum(
        tokens
        for key in (
            "input_tokens",
            "cache_read_input_tokens",
            "cache_creation_input_tokens",
        )
        if isinstance(tokens := usage.get(key), int)
    )


def notice(previous: int, current: int) -> str | None:
    """What to say when the context moved from previous to current."""
    match (band(previous) < band(current), band(current)):
        case (False, _):
            return None
        case (True, 1):
            template = WARN
        case _:
            template = STOP
    return template.format(size=current // 1000, stop=STOP_AT // 1000)


def band(size: int) -> int:
    """0 under budget, 1 warned, 2 and up one per STOP_STEP past STOP_AT."""
    if size < WARN_AT:
        return 0
    if size < STOP_AT:
        return 1
    return 2 + (size - STOP_AT) // STOP_STEP


def output(message: str) -> dict[str, dict[str, str]]:
    return {
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": message,
        }
    }


if __name__ == "__main__":
    main()
