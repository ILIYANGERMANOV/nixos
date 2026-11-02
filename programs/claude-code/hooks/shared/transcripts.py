"""Finds the transcript of the agent a hook fired in and parses its lines, for the guards."""

from dataclasses import dataclass
from pathlib import Path
from typing import NewType, assert_never

from hook_event import (
    Agent,
    Caller,
    Json,
    MainAgent,
    Subagent,
    ToolUseId,
    UnnamedSubagent,
    parse_json,
)

MessageId = NewType("MessageId", str)


@dataclass(frozen=True, slots=True)
class BashUse:
    use_id: ToolUseId
    command: str


@dataclass(frozen=True, slots=True)
class OtherUse:
    pass


type ToolUse = BashUse | OtherUse


@dataclass(frozen=True, slots=True)
class AssistantLine:
    """One content block of a model call. `context` is 0 on a line with no usage."""

    message_id: MessageId | None
    context: int
    tool_uses: list[ToolUse]


def own_transcript(caller: Caller) -> Path:
    """The transcript of the agent that made the call.

    `transcript_path` always names the main session's. A subagent's, at any
    depth, sits under the session's own directory, named after its `agent_id`.
    """
    match caller.agent:
        case Subagent(agent_id):
            return (
                caller.transcript_path.with_suffix("")
                / "subagents"
                / f"agent-{agent_id}.jsonl"
            )
        case MainAgent() | UnnamedSubagent():
            return caller.transcript_path
        case _:
            assert_never(caller.agent)


def in_subagent(agent: Agent) -> bool:
    match agent:
        case MainAgent():
            return False
        case Subagent() | UnnamedSubagent():
            return True
        case _:
            assert_never(agent)


def parse_assistant_line(line: bytes) -> AssistantLine | None:
    """None for any other line, and for a partial line of a tail or a running write."""
    match parse_line(line):
        case {"type": "assistant", "message": dict(message)}:
            return AssistantLine(
                parse_message_id(message.get("id")),
                parse_context(message.get("usage")),
                parse_tool_uses(message.get("content")),
            )
        case _:
            return None


def parse_line(line: bytes) -> Json:
    try:
        return parse_json(line)
    except ValueError:
        return None


def parse_message_id(value: Json) -> MessageId | None:
    match value:
        case str(message_id):
            return MessageId(message_id)
        case _:
            return None


def parse_context(usage: Json) -> int:
    match usage:
        case dict(counts):
            return sum(
                tokens
                for key in (
                    "input_tokens",
                    "cache_read_input_tokens",
                    "cache_creation_input_tokens",
                )
                if isinstance(tokens := counts.get(key), int)
            )
        case _:
            return 0


def parse_tool_uses(content: Json) -> list[ToolUse]:
    match content:
        case list(blocks):
            return [
                use for block in blocks if (use := parse_tool_use(block)) is not None
            ]
        case _:
            return []


def parse_tool_use(block: Json) -> ToolUse | None:
    match block:
        case {
            "type": "tool_use",
            "name": "Bash",
            "id": use_id,
            "input": {"command": str(command)},
        }:
            return BashUse(ToolUseId(str(use_id)), command)
        case {"type": "tool_use"}:
            return OtherUse()
        case _:
            return None
