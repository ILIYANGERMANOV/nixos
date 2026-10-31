"""Parses what Claude Code hands a hook into narrow types, for the guards.

A parser raises ValueError on input it does not understand. Each guard catches
it once, in `main`, and fails open.
"""

import json
from dataclasses import dataclass
from pathlib import Path
from typing import NewType, cast

# What `json.loads` can return, spelled out because typeshed says Any.
type Json = None | bool | int | float | str | list[Json] | dict[str, Json]

AgentId = NewType("AgentId", str)
ToolUseId = NewType("ToolUseId", str)


@dataclass(frozen=True, slots=True)
class BashCall:
    command: str
    background: bool
    tool_use_id: ToolUseId | None


@dataclass(frozen=True, slots=True)
class ReadCall:
    file_path: str
    bounded: bool


@dataclass(frozen=True, slots=True)
class MainAgent:
    pass


@dataclass(frozen=True, slots=True)
class Subagent:
    agent_id: AgentId


@dataclass(frozen=True, slots=True)
class UnnamedSubagent:
    """A null `agent_id`: in a subagent, but with no transcript name to find."""


type Agent = MainAgent | Subagent | UnnamedSubagent


@dataclass(frozen=True, slots=True)
class Caller:
    """Who made the call, read off any hook event. Parsing it never fails.

    A hook that never reads the transcript must not fail on one that is absent,
    so `transcript_path` stays None until a reader asks for it.
    """

    agent: Agent
    transcript_path: Path | None


def parse_json(text: str | bytes) -> Json:
    return cast("Json", json.loads(text))


def parse_bash_call(event: Json) -> BashCall:
    match event:
        case {"tool_input": {"command": str(command)} as tool_input}:
            background = tool_input.get("run_in_background") is True
            return BashCall(command, background, parse_tool_use_id(event))
        case _:
            raise ValueError("no Bash command")


def parse_read_call(event: Json) -> ReadCall:
    match event:
        case {"tool_input": {"file_path": str(file_path)} as tool_input}:
            return ReadCall(file_path, tool_input.get("limit") is not None)
        case _:
            raise ValueError("no Read file_path")


def parse_caller(event: Json) -> Caller:
    return Caller(parse_agent(event), parse_transcript_path(event))


def parse_tool_use_id(event: Json) -> ToolUseId | None:
    match event:
        case {"tool_use_id": str(tool_use_id)}:
            return ToolUseId(tool_use_id)
        case _:
            return None


def parse_agent(event: Json) -> Agent:
    match event:
        case {"agent_id": None}:
            return UnnamedSubagent()
        case {"agent_id": agent_id}:
            return Subagent(AgentId(str(agent_id)))
        case _:
            return MainAgent()


def parse_transcript_path(event: Json) -> Path | None:
    match event:
        case {"transcript_path": str(path)}:
            return Path(path)
        case _:
            return None
