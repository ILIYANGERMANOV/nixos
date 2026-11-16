"""The context guard: what it tells an agent after a call, from the event's context.

How a backend reads the context from its transcript is the backend's test.
"""

import os

from agent_hook import Agent, AgentId, ContextSize, Note, Role
from guard_harness import SUBAGENT, Case, after_tool_event, guard_cases, observe

GUARD = os.environ["CONTEXT_GUARD"]

LEAD = None
ENGINEER = Agent(AgentId("e1"), Role("engineer"))
NO_ROLE = Agent(AgentId("n1"), None)

# Want: what the notice holds. Given: the caller, the context before and after.
NOTICE_CASES: list[Case[tuple[Agent | None, ContextSize], str]] = [
    ("Context 300k", "the lead warns at 300k", (LEAD, ContextSize(300_600, 298_600))),
    ("over the 400k", "the lead stops at 400k", (LEAD, ContextSize(400_600, 398_600))),
    (
        "stop now",
        "another 10k past the budget says stop again",
        (LEAD, ContextSize(410_600, 408_600)),
    ),
    (
        "Context 300k",
        "a first call past the line warns",
        (LEAD, ContextSize(300_600, None)),
    ),
    (
        "Context 260k",
        "an engineer warns at 260k",
        (ENGINEER, ContextSize(260_600, 258_600)),
    ),
    (
        "over the 350k",
        "an engineer stops at 350k",
        (ENGINEER, ContextSize(350_600, 348_600)),
    ),
    (
        "Context 220k",
        "any other role warns at 220k",
        (SUBAGENT, ContextSize(220_600, 218_600)),
    ),
    (
        "over the 300k",
        "any other role stops at 300k",
        (SUBAGENT, ContextSize(300_600, 298_600)),
    ),
    (
        "Context 220k",
        "an agent naming no role warns at 220k",
        (NO_ROLE, ContextSize(220_600, 218_600)),
    ),
    (
        "over the 300k",
        "an agent naming no role stops at 300k",
        (NO_ROLE, ContextSize(300_600, 298_600)),
    ),
]

SILENT = Note()
SILENT_CASES: list[Case[tuple[Agent | None, ContextSize | None], Note]] = [
    (SILENT, "under the budget it says nothing", (LEAD, ContextSize(2_000, 1_000))),
    (SILENT, "the 60k check line stays silent", (LEAD, ContextSize(60_000, 58_000))),
    (
        SILENT,
        "the lead crossing a worker's 220k says nothing",
        (LEAD, ContextSize(220_600, 218_600)),
    ),
    (
        SILENT,
        "an engineer crossing a worker's 220k says nothing",
        (ENGINEER, ContextSize(220_600, 218_600)),
    ),
    (
        SILENT,
        "staying past the warning says nothing",
        (SUBAGENT, ContextSize(221_000, 220_000)),
    ),
    (
        SILENT,
        "staying past the budget says nothing",
        (SUBAGENT, ContextSize(301_000, 300_000)),
    ),
    (
        SILENT,
        "a compacted context says nothing",
        (SUBAGENT, ContextSize(90_000, 310_000)),
    ),
    (SILENT, "an unknown context says nothing", (LEAD, None)),
]


@guard_cases(NOTICE_CASES)
def test_notice(want: str, given: tuple[Agent | None, ContextSize]) -> None:
    agent, context = given
    match observe([GUARD], after_tool_event(context, agent)):
        case Note(context=str(told)):
            assert want in told
        case silent:
            raise AssertionError(f"no notice: {silent}")


@guard_cases(SILENT_CASES)
def test_silence(want: Note, given: tuple[Agent | None, ContextSize | None]) -> None:
    agent, context = given
    assert observe([GUARD], after_tool_event(context, agent)) == want


def test_malformed_input_says_nothing() -> None:
    assert observe([GUARD], "not json") == SILENT
