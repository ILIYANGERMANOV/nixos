"""What a guard reads from the event Claude Code hands a hook."""

from pathlib import Path

import pytest
from hook_event import (
    Agent,
    AgentId,
    BashCall,
    Caller,
    Json,
    MainAgent,
    ReadCall,
    Subagent,
    ToolUseId,
    UnnamedSubagent,
    parse_agent,
    parse_bash_call,
    parse_caller,
    parse_json,
    parse_read_call,
)


def test_a_bash_event_reads_as_its_command_and_tool_use() -> None:
    event = parse_json(
        '{"tool_input": {"command": "ls", "run_in_background": true}, "tool_use_id": "u1"}'
    )

    assert parse_bash_call(event) == BashCall(
        "ls", background=True, tool_use_id=ToolUseId("u1")
    )


@pytest.mark.parametrize(
    "tool_input",
    [{"command": "ls"}, {"command": "ls", "run_in_background": "true"}],
)
def test_a_bash_event_with_no_true_flag_runs_in_the_foreground_without_an_id(
    tool_input: Json,
) -> None:
    event: Json = {"tool_input": tool_input}

    assert parse_bash_call(event) == BashCall("ls", background=False, tool_use_id=None)


def test_a_read_is_bounded_by_any_limit_it_sets() -> None:
    event: Json = {"tool_input": {"file_path": "/a", "limit": 0}}

    assert parse_read_call(event) == ReadCall("/a", bounded=True)


def test_a_read_without_a_limit_is_unbounded() -> None:
    event: Json = {"tool_input": {"file_path": "/a", "limit": None}}

    assert parse_read_call(event) == ReadCall("/a", bounded=False)


@pytest.mark.parametrize(
    "event",
    [None, {}, {"tool_input": {}}, {"tool_input": {"command": 1}}],
)
def test_a_bash_event_with_no_command_is_refused(event: Json) -> None:
    with pytest.raises(ValueError, match="no Bash command"):
        _ = parse_bash_call(event)


def test_a_read_event_with_no_file_path_is_refused() -> None:
    with pytest.raises(ValueError, match="no Read file_path"):
        _ = parse_read_call({"tool_input": {"command": "ls"}})


@pytest.mark.parametrize(
    ("event", "agent"),
    [
        ({}, MainAgent()),
        ({"agent_id": "a1"}, Subagent(AgentId("a1"))),
        ({"agent_id": None}, UnnamedSubagent()),
    ],
)
def test_the_agent_is_named_by_agent_id(event: Json, agent: Agent) -> None:
    assert parse_agent(event) == agent


def test_a_caller_names_its_agent_and_the_session_transcript() -> None:
    event: Json = {"agent_id": "a1", "transcript_path": "/s/main.jsonl"}

    assert parse_caller(event) == Caller(Subagent(AgentId("a1")), Path("/s/main.jsonl"))


def test_a_caller_without_a_transcript_is_refused() -> None:
    with pytest.raises(ValueError, match="no transcript_path"):
        _ = parse_caller({"agent_id": "a1"})
