"""afterTool hook on every tool: tell an agent its context is past the budget.

Reads a neutral event (agent_hook.py) on stdin, whose `context` holds the
tokens the newest model call sent and those of the last earlier call that ran a
tool, the last the hook saw. So it needs no state, loses no crossing on a
text-only reply, and speaks only when the context crosses a line: once at the
warn limit, at the stop limit, then every STOP_STEP past it. The limits depend
on who calls: the top-level session (no agent), an agent by its role, or
OTHER for any role the table does not name. With no earlier call the
newest one counts as a crossing. Calls sent together share a message and may
each repeat the notice. The hook only talks: blocking tools here would also
block the commit and the push the notice asks for. Everything else, including
any input this script does not understand or an event with no context, prints
nothing: the guard fails open.
"""

import sys
from typing import NamedTuple

from agent_hook import (
    AfterTool,
    Agent,
    ContextSize,
    Note,
    Role,
    emit_result,
    parse_event,
)

STOP_STEP = 10_000
WARN = (
    "Context {size}k, budget {stop}k: stop there. Until then, never run a check "
    "over about 4 minutes yourself: commit, push and hand back naming it."
)
HAND_BACK = (
    "Context {size}k, over the {stop}k budget: stop now. Commit, push, hand back "
    "a short note (files, decisions, what remains, how to verify); a fresh agent "
    "continues."
)
# The top-level agent has no caller to hand back to: the user resumes it.
RESUME = (
    "Context {size}k, over the {stop}k budget: stop now. Commit, push, write a "
    "short note (files, decisions, what remains, how to verify) to your notes "
    "dir, and tell the user to run `/chief resume` in a fresh session."
)


class Limits(NamedTuple):
    """Context sizes in tokens: warn once at `warn`, stop with `stop_text` at `stop`."""

    warn: int
    stop: int
    stop_text: str = HAND_BACK


# Orchestrators get more room for large tasks.
LEAD = Limits(warn=300_000, stop=400_000, stop_text=RESUME)
ROLE_LIMITS = {Role("engineer"): Limits(warn=260_000, stop=350_000)}
OTHER = Limits(warn=220_000, stop=300_000)


def main() -> None:
    try:
        event = parse_event(sys.stdin.read())
    except Exception:  # noqa: BLE001 - any failure must let the call through
        sys.exit(0)

    match event:
        case AfterTool(
            agent=agent, context=ContextSize(tokens=current, previous=previous)
        ):
            message = notice(previous or 0, current, limits(agent))
        case _:
            message = None
    if message is not None:
        print(emit_result(Note(message)))


def limits(agent: Agent | None) -> Limits:
    """The warn and stop limits of the caller; a role-less agent gets OTHER."""
    match agent:
        case None:
            return LEAD
        case Agent(role=role):
            return ROLE_LIMITS.get(role, OTHER) if role else OTHER


def notice(previous: int, current: int, limit: Limits) -> str | None:
    """What to say when the context moved from previous to current."""
    before, after = band(previous, limit), band(current, limit)
    match (before < after, after):
        case (False, _):
            return None
        case (True, 1):
            template = WARN
        case _:
            template = limit.stop_text
    return template.format(size=current // 1000, stop=limit.stop // 1000)


def band(size: int, limit: Limits) -> int:
    """0 under budget, 1 warned, 2 and up one per STOP_STEP past stop."""
    if size < limit.warn:
        return 0
    if size < limit.stop:
        return 1
    return 2 + (size - limit.stop) // STOP_STEP


if __name__ == "__main__":
    main()
