"""afterTool hook on every tool: tell an agent its context is past the budget.

Reads a neutral event (agent_hook.py) on stdin, whose `context` holds the
tokens the newest model call sent and those of the last earlier call that ran a
tool, the last the hook saw. So it needs no state, loses no crossing on a
text-only reply, and speaks only when the context crosses a line: once at
WARN_AT, at STOP_AT, then every STOP_STEP past it. With no earlier call the
newest one counts as a crossing. Calls sent together share a message and may
each repeat the notice. The hook only talks: blocking tools here would also
block the commit and the push the notice asks for. Everything else, including
any input this script does not understand or an event with no context, prints
nothing: the guard fails open.
"""

import sys

from agent_hook import AfterTool, ContextSize, Note, emit_result, parse_event

WARN_AT = 150_000
STOP_AT = 220_000
STOP_STEP = 10_000
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
        event = parse_event(sys.stdin.read())
    except Exception:  # noqa: BLE001 - any failure must let the call through
        sys.exit(0)

    match event:
        case AfterTool(context=ContextSize(tokens=current, previous=previous)):
            message = notice(previous or 0, current)
        case _:
            message = None
    if message is not None:
        print(emit_result(Note(message)))


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


if __name__ == "__main__":
    main()
