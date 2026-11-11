"""The context guard: what it tells an agent after a call, from its transcript."""

import json
import os
from pathlib import Path
from typing import cast

from guard_harness import (
    ALLOWED,
    Case,
    agent_fields,
    guard_cases,
    run_guard,
    session_with,
)

GUARD = os.environ["CONTEXT_GUARD"]


def usage_line(
    message_id: str,
    input_tokens: int,
    cache_read: int,
    block: str = "tool_use",
    cache_creation: int = 500,
) -> str:
    """An assistant line of a call, with one block of type `block`."""
    return json.dumps(
        {
            "type": "assistant",
            "message": {
                "id": message_id,
                "content": [{"type": block}],
                "usage": {
                    "input_tokens": input_tokens,
                    "cache_read_input_tokens": cache_read,
                    "cache_creation_input_tokens": cache_creation,
                },
            },
        }
    )


def transcript(*lines: str) -> str:
    return "".join(line + "\n" for line in lines)


def two_calls(first: int, second: int) -> str:
    return transcript(usage_line("a", 100, first), usage_line("b", 100, second))


AT_148K = usage_line("a", 100, 148000)
AT_150K = usage_line("b", 100, 150000)

# Want: what the notice holds. Given: the main agent's transcript.
NOTICE_CASES: list[Case[str, str]] = [
    ("Context 150k", "crossing 150k warns", two_calls(148000, 150000)),
    ("stop now", "crossing 220k says stop", two_calls(218000, 220000)),
    (
        "stop now",
        "another 10k past the budget says stop again",
        two_calls(228000, 230000),
    ),
    (
        "Context 150k",
        "a message of several lines counts as one call",
        transcript(AT_148K, AT_150K, AT_150K),
    ),
    ("Context 150k", "a first call past the line warns", transcript(AT_150K)),
    (
        "Context 150k",
        "a partial last line is skipped",
        transcript(AT_148K, AT_150K, '{"type":"assis'),
    ),
    (
        "Context 151k",
        "a crossing on a text-only reply warns at the next call",
        transcript(
            AT_148K, usage_line("t", 100, 150000, "text"), usage_line("b", 100, 151000)
        ),
    ),
]

SILENT = ""
SILENT_CASES: list[Case[str, str]] = [
    (SILENT, "under the budget it says nothing", two_calls(1000, 2000)),
    (SILENT, "the 60k check line stays silent", two_calls(58000, 60000)),
    (SILENT, "staying past 150k says nothing", two_calls(150000, 151000)),
    (SILENT, "staying past 220k says nothing", two_calls(220000, 221000)),
    (SILENT, "a compacted context says nothing", two_calls(230000, 90000)),
    (
        SILENT,
        "an empty synthetic call is skipped",
        transcript(
            usage_line("a", 100, 150000),
            usage_line("c", 0, 0, cache_creation=0),
            AT_150K,
        ),
    ),
    (
        SILENT,
        "a text-only reply past the line repeats nothing",
        transcript(
            usage_line("a", 100, 151000),
            usage_line("t", 100, 152000, "text"),
            usage_line("b", 100, 153000),
        ),
    ),
    (
        SILENT,
        "a call's text block does not hide its tool call",
        transcript(
            AT_148K,
            usage_line("b", 100, 150000, "text"),
            AT_150K,
            usage_line("c", 100, 151000),
        ),
    ),
]

RAW_CASES: list[Case[str]] = [
    (ALLOWED, "malformed input is allowed", "not json"),
    (ALLOWED, "input without a transcript is allowed", '{"tool_input": {}}'),
]


@guard_cases(NOTICE_CASES)
def test_notice(tmp_path: Path, want: str, given: str) -> None:
    assert want in notice(session_with(tmp_path, given, {}))


@guard_cases(SILENT_CASES)
def test_silence(tmp_path: Path, want: str, given: str) -> None:
    assert notice(session_with(tmp_path, given, {})) == want


@guard_cases(RAW_CASES)
def test_raw_input(want: int, given: str) -> None:
    assert run_guard([GUARD], given).returncode == want


def test_a_subagent_is_judged_on_its_own_transcript(tmp_path: Path) -> None:
    session = session_with(
        tmp_path, two_calls(1000, 1000), {"deep": two_calls(148000, 150000)}
    )

    assert "Context 150k" in notice(session, "deep")


def test_a_subagent_is_not_judged_on_the_parents_transcript(tmp_path: Path) -> None:
    session = session_with(
        tmp_path, two_calls(148000, 150000), {"deep": two_calls(1000, 1000)}
    )

    assert notice(session, "deep") == SILENT


def test_a_missing_transcript_says_nothing(tmp_path: Path) -> None:
    session = session_with(tmp_path, two_calls(148000, 150000), {})

    assert notice(session, "gone") == SILENT


def notice(session: Path, agent: str | None = None) -> str:
    """What the guard tells `agent`, or the main agent, after a call."""
    event = {
        "hook_event_name": "PostToolUse",
        "tool_name": "Bash",
        "transcript_path": str(session),
    }
    stdout = run_guard([GUARD], json.dumps(event | agent_fields(agent))).stdout
    return additional_context(stdout) if stdout else SILENT


def additional_context(stdout: str) -> str:
    output = cast("dict[str, dict[str, str]]", json.loads(stdout))
    return output["hookSpecificOutput"]["additionalContext"]
