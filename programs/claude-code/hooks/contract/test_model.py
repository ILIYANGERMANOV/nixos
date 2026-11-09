"""The probe's scripted Messages API: who asks, which turn it gets, what it saw."""

import json
from typing import cast

from hypothesis import given
from hypothesis import strategies as st
from model import (
    ALLOW,
    HANDBACK_TAG,
    ORIGINAL_COMMAND,
    REWRITE_TAG,
    SUBAGENT_MARKER,
    SUMMARY,
    Json,
    Speaker,
    Text,
    ToolUse,
    Turn,
    Unscripted,
    reply,
    response,
    seen,
)

LEAD_SYSTEM: Json = [{"type": "text", "text": "You are Claude Code."}]
SUBAGENT_SYSTEM: Json = [
    {"type": "text", "text": f"{SUBAGENT_MARKER}: run the turns you are given."}
]


def conversation(system: Json, turns: int, **extra: Json) -> dict[str, Json]:
    """A request after `turns` tool calls, each answered with a tool result."""
    history: list[Json] = [
        {"role": "user", "content": [{"type": "text", "text": "probe"}]}
    ]
    for turn in range(turns):
        history.append(
            {
                "role": "assistant",
                "content": [
                    {"type": "tool_use", "id": f"t{turn}", "name": "Bash", "input": {}}
                ],
            }
        )
        history.append(
            {
                "role": "user",
                "content": [
                    {"type": "tool_result", "tool_use_id": f"t{turn}", "content": "ok"}
                ],
            }
        )
    return {
        "model": "claude-opus-5-5",
        "system": system,
        "messages": history,
        "stream": True,
        **extra,
    }


def test_the_lead_opens_with_the_command_the_hook_rewrites() -> None:
    assert reply(conversation(LEAD_SYSTEM, 0)) == ToolUse(
        "Bash", {"command": ORIGINAL_COMMAND, "description": ORIGINAL_COMMAND}
    )


def test_the_lead_spawns_its_subagent_in_the_foreground() -> None:
    match reply(conversation(LEAD_SYSTEM, 3)):
        case ToolUse("Agent", {"subagent_type": "probe", "run_in_background": False}):
            pass
        case other:
            raise AssertionError(other)


def test_the_lead_ends_in_text_after_the_spawn() -> None:
    assert reply(conversation(LEAD_SYSTEM, 4)) == Text("LEAD-DONE")


def test_a_request_past_the_script_names_its_speaker_and_turn() -> None:
    assert reply(conversation(LEAD_SYSTEM, 5)) == Unscripted(Speaker.LEAD, 5)


def test_the_subagent_is_told_apart_by_the_marker_in_its_system_prompt() -> None:
    assert reply(conversation(SUBAGENT_SYSTEM, 0)) == ToolUse(
        "Bash", {"command": "pwd", "description": "pwd"}
    )


def test_the_subagent_ends_by_handing_back() -> None:
    match reply(conversation(SUBAGENT_SYSTEM, 3)):
        case ToolUse("SubagentHandback", {"message": str()}):
            pass
        case other:
            raise AssertionError(other)


def test_the_classifier_is_always_allowed_whatever_the_history() -> None:
    request = conversation(LEAD_SYSTEM, 7, stop_sequences=["</severity>"], stream=False)

    assert reply(request) == ALLOW


def test_a_summary_request_is_the_compactor_even_with_a_system_note_last() -> None:
    request = conversation(LEAD_SYSTEM, 4)
    request["messages"] = [
        *as_list(request["messages"]),
        {
            "role": "user",
            "content": [{"type": "text", "text": "Reply with a <summary> block."}],
        },
        {"role": "system", "content": "Another Claude session sent a message."},
    ]

    assert reply(request) == SUMMARY


def test_seen_lists_the_tools_offered() -> None:
    request = conversation(
        SUBAGENT_SYSTEM, 0, tools=[{"name": "Bash"}, {"name": "SubagentHandback"}]
    )

    assert seen(request).tools == ["Bash", "SubagentHandback"]


def test_a_witness_counts_only_in_what_is_new_since_the_last_turn() -> None:
    request = conversation(LEAD_SYSTEM, 2)
    history = as_list(request["messages"])
    history[2] = {
        "role": "user",
        "content": [{"type": "tool_result", "content": REWRITE_TAG}],
    }
    history[-1] = {
        "role": "user",
        "content": [
            {
                "type": "tool_result",
                "content": [{"type": "text", "text": f"report {HANDBACK_TAG}"}],
            }
        ],
    }

    assert seen(request).witnesses == [HANDBACK_TAG]


turns = st.one_of(
    st.builds(Text, st.text()),
    st.builds(
        ToolUse,
        st.text(min_size=1),
        st.dictionaries(st.text(), st.one_of(st.text(), st.booleans(), st.integers())),
    ),
)


@given(turns)
def test_the_stream_carries_the_same_message_as_the_plain_reply(turn: Turn) -> None:
    _, plain = response(turn, {"model": "m", "stream": False}, "1")
    content_type, streamed = response(turn, {"model": "m", "stream": True}, "1")

    assert content_type == "text/event-stream"
    assert assemble(streamed.decode()) == json.loads(plain)


def assemble(sse: str) -> Json:
    """The client's side of the stream: the message with each block's deltas applied."""
    events: list[Json] = [
        json.loads(line.removeprefix("data: "))
        for line in sse.splitlines()
        if line.startswith("data: ")
    ]
    message: dict[str, Json] = {}
    blocks: list[dict[str, Json]] = []
    partial = ""
    for event in events:
        match event:
            case {"type": "message_start", "message": dict() as start}:
                message = start
            case {"type": "content_block_start", "content_block": dict() as block}:
                blocks.append(block)
            case {
                "type": "content_block_delta",
                "delta": {"type": "text_delta", "text": str(piece)},
            }:
                blocks[-1] = {**blocks[-1], "text": f"{blocks[-1].get('text')}{piece}"}
            case {
                "type": "content_block_delta",
                "delta": {"type": "input_json_delta", "partial_json": str(part)},
            }:
                partial += part
            case {"type": "content_block_stop"} if partial:
                blocks[-1] = {**blocks[-1], "input": cast("Json", json.loads(partial))}
            case {"type": "message_delta", "delta": dict() as delta}:
                message = {**message, **delta}
            case _:
                pass
    content: list[Json] = [*blocks]
    return {**message, "content": content}


def as_list(value: Json) -> list[Json]:
    assert isinstance(value, list)
    return value
