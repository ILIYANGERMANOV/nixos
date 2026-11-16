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

from agent_hook import (
    AfterTool,
    Agent,
    ContextSize,
    Note,
    Role,
    emit_result,
    parse_event,
)

# Warn and stop limits in tokens. Orchestrators get more room for large tasks.
LEAD = (300_000, 400_000)
ROLE_LIMITS = {Role("engineer"): (260_000, 350_000)}
OTHER = (220_000, 300_000)
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
        case AfterTool(
            agent=agent, context=ContextSize(tokens=current, previous=previous)
        ):
            warn, stop = limits(agent)
            message = notice(previous or 0, current, warn, stop)
        case _:
            message = None
    if message is not None:
        print(emit_result(Note(message)))


def limits(agent: Agent | None) -> tuple[int, int]:
    """The warn and stop limits of the caller; a role-less agent gets OTHER."""
    match agent:
        case None:
            return LEAD
        case Agent(role=role):
            return ROLE_LIMITS.get(role, OTHER) if role else OTHER


def notice(previous: int, current: int, warn: int, stop: int) -> str | None:
    """What to say when the context moved from previous to current."""
    before, after = band(previous, warn, stop), band(current, warn, stop)
    match (before < after, after):
        case (False, _):
            return None
        case (True, 1):
            template = WARN
        case _:
            template = STOP
    return template.format(size=current // 1000, stop=stop // 1000)


def band(size: int, warn: int, stop: int) -> int:
    """0 under budget, 1 warned, 2 and up one per STOP_STEP past stop."""
    if size < warn:
        return 0
    if size < stop:
        return 1
    return 2 + (size - stop) // STOP_STEP


if __name__ == "__main__":
    main()
