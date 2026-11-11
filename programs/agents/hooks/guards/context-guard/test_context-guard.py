"""The context guard: what it tells an agent after a call, from the event's context.

How a backend reads the context from its transcript is the backend's test.
"""

import os

from agent_hook import ContextSize, Note
from guard_harness import Case, after_tool_event, guard_cases, observe

GUARD = os.environ["CONTEXT_GUARD"]

# Want: what the notice holds. Given: the context before and after the call.
NOTICE_CASES: list[Case[ContextSize, str]] = [
    ("Context 150k", "crossing 150k warns", ContextSize(150_600, 148_600)),
    ("stop now", "crossing 220k says stop", ContextSize(220_600, 218_600)),
    (
        "stop now",
        "another 10k past the budget says stop again",
        ContextSize(230_600, 228_600),
    ),
    ("Context 150k", "a first call past the line warns", ContextSize(150_600, None)),
]

SILENT = Note()
SILENT_CASES: list[Case[ContextSize | None, Note]] = [
    (SILENT, "under the budget it says nothing", ContextSize(2_000, 1_000)),
    (SILENT, "the 60k check line stays silent", ContextSize(60_000, 58_000)),
    (SILENT, "staying past 150k says nothing", ContextSize(151_000, 150_000)),
    (SILENT, "staying past 220k says nothing", ContextSize(221_000, 220_000)),
    (SILENT, "a compacted context says nothing", ContextSize(90_000, 230_000)),
    (SILENT, "an unknown context says nothing", None),
]


@guard_cases(NOTICE_CASES)
def test_notice(want: str, given: ContextSize) -> None:
    match observe([GUARD], after_tool_event(given)):
        case Note(context=str(told)):
            assert want in told
        case silent:
            raise AssertionError(f"no notice: {silent}")


@guard_cases(SILENT_CASES)
def test_silence(want: Note, given: ContextSize | None) -> None:
    assert observe([GUARD], after_tool_event(given)) == want


def test_malformed_input_says_nothing() -> None:
    assert observe([GUARD], "not json") == SILENT
