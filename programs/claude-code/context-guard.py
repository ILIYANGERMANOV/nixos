"""PostToolUse hook: tell an agent its context is past the budget.

Reads the hook input from stdin and the agent's own transcript, whose assistant
lines carry the context each call sent. It compares the newest call with the
one before, so it needs no state and speaks only when the context crosses a
line: once at WARN_AT, at STOP_AT, then every STOP_STEP past it. Calls sent
together share a message and may each repeat the notice. The hook only talks:
blocking tools here would also block the commit and the push the notice asks
for. Everything else, including any input this script does not understand,
prints nothing and exits 0: the guard fails open.
"""

import json
import os
import sys
from pathlib import Path

from transcripts import own_transcript, parse_line

WARN_AT = 150_000
STOP_AT = 220_000
STOP_STEP = 10_000
# Enough for two calls unless a single result is larger, which only costs the
# comparison: the newest call then counts as a crossing.
TAIL_BYTES = 256 * 1024
WARN = (
    "Context {size}k, budget {stop}k: stop there. Until then, never wait on a "
    "check over about 4 minutes: commit, push and hand back naming it."
)
STOP = (
    "Context {size}k, over the {stop}k budget: stop now. Commit, push, hand back "
    "a short note (files, decisions, what remains, how to verify); a fresh agent "
    "continues."
)


def main() -> None:
    try:
        event = json.load(sys.stdin)
        contexts = recent_contexts(own_transcript(event))
    except Exception:
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
    """The context of each call in the file's tail, newest first.

    One message spans a line per content block, each with the same usage.
    """
    contexts: dict[str, int] = {}
    for line in reversed(tail_lines(path)):
        match parse_line(line):
            case {
                "type": "assistant",
                "message": {"id": message_id, "usage": usage},
            } if context(usage) > 0:
                contexts.setdefault(message_id, context(usage))
            case _:
                pass
    return list(contexts.values())


def tail_lines(path: Path) -> list[bytes]:
    with path.open("rb") as file:
        file.seek(0, os.SEEK_END)
        file.seek(max(0, file.tell() - TAIL_BYTES))
        return file.read().splitlines()


def context(usage: dict) -> int:
    return sum(
        usage.get(key, 0)
        for key in (
            "input_tokens",
            "cache_read_input_tokens",
            "cache_creation_input_tokens",
        )
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


def output(message: str) -> dict:
    return {
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": message,
        }
    }


if __name__ == "__main__":
    main()
