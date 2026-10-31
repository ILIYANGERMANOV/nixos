"""Parses what Claude Code hands a hook into narrow types, for the guards.

A parser raises ValueError on input it does not understand. Each guard catches
it once, in `main`, and fails open.
"""

import json
from dataclasses import dataclass
from typing import cast

# What `json.loads` can return, spelled out because typeshed says Any.
type Json = None | bool | int | float | str | list[Json] | dict[str, Json]


@dataclass(frozen=True, slots=True)
class BashCall:
    command: str
    background: bool


@dataclass(frozen=True, slots=True)
class ReadCall:
    file_path: str
    bounded: bool


def parse_json(text: str | bytes) -> Json:
    return cast("Json", json.loads(text))


def parse_bash_call(event: Json) -> BashCall:
    match event:
        case {"tool_input": {"command": str(command)} as tool_input}:
            background = tool_input.get("run_in_background") is True
            return BashCall(command, background)
        case _:
            raise ValueError("no Bash command")


def parse_read_call(event: Json) -> ReadCall:
    match event:
        case {"tool_input": {"file_path": str(file_path)} as tool_input}:
            return ReadCall(file_path, tool_input.get("limit") is not None)
        case _:
            raise ValueError("no Read file_path")
