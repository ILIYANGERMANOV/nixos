"""Finding an agent's transcript and reading its lines."""

import json
from pathlib import Path

import pytest
from hook_event import (
    Agent,
    AgentId,
    Caller,
    Json,
    MainAgent,
    Subagent,
    ToolUseId,
    UnnamedSubagent,
)
from transcripts import (
    AssistantLine,
    BashUse,
    MessageId,
    OtherUse,
    in_subagent,
    own_transcript,
    parse_assistant_line,
)

MAIN = Path("/projects/p/session.jsonl")


def assistant_line(message: Json) -> bytes:
    return json.dumps({"type": "assistant", "message": message}).encode()


def test_a_subagent_reads_its_own_file_under_the_session() -> None:
    caller = Caller(Subagent(AgentId("a1")), MAIN)

    assert own_transcript(caller) == Path(
        "/projects/p/session/subagents/agent-a1.jsonl"
    )


@pytest.mark.parametrize("agent", [MainAgent(), UnnamedSubagent()])
def test_an_agent_with_no_name_reads_the_session_transcript(agent: Agent) -> None:
    assert own_transcript(Caller(agent, MAIN)) == MAIN


def test_the_main_agent_is_not_in_a_subagent() -> None:
    assert not in_subagent(MainAgent())


@pytest.mark.parametrize("agent", [Subagent(AgentId("a1")), UnnamedSubagent()])
def test_a_subagent_is_in_a_subagent(agent: Agent) -> None:
    assert in_subagent(agent)


def test_an_assistant_line_sums_its_context_and_reads_its_tool_uses() -> None:
    line = assistant_line(
        {
            "id": "m1",
            "usage": {
                "input_tokens": 1,
                "cache_read_input_tokens": 20,
                "cache_creation_input_tokens": 300,
                "output_tokens": 4000,
            },
            "content": [
                {"type": "text", "text": "hi"},
                {
                    "type": "tool_use",
                    "name": "Bash",
                    "id": "u1",
                    "input": {"command": "ls"},
                },
                {"type": "tool_use", "name": "Read", "id": "u2", "input": {}},
            ],
        }
    )

    assert parse_assistant_line(line) == AssistantLine(
        MessageId("m1"),
        321,
        [BashUse(ToolUseId("u1"), "ls"), OtherUse()],
    )


def test_an_assistant_line_with_no_usage_has_no_context() -> None:
    assert parse_assistant_line(assistant_line({})) == AssistantLine(None, 0, [])


@pytest.mark.parametrize(
    "line",
    [b'{"type": "user", "message": {}}', b'{"type": "assistant", "mess', b""],
)
def test_any_other_line_is_not_an_assistant_line(line: bytes) -> None:
    assert parse_assistant_line(line) is None
