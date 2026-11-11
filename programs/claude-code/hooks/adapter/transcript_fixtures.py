"""What the adapter tests share: transcript lines as Claude Code writes them,
one line per content block, every one with its model call's usage."""

import json
from pathlib import Path

from agent_hook import Json, JsonObject

THINKING: JsonObject = {"type": "text", "text": "thinking aloud"}


def model_call(message_id: str, tokens: int, *blocks: JsonObject) -> list[JsonObject]:
    """A model call's lines, its usage split as Claude splits it."""
    usage: JsonObject = {
        "input_tokens": 3,
        "cache_read_input_tokens": tokens - 13,
        "cache_creation_input_tokens": 10,
        "output_tokens": 99,
    }
    return [assistant(message_id, usage, block) for block in blocks or [THINKING]]


def assistant(message_id: str, usage: JsonObject, block: Json) -> JsonObject:
    return {
        "type": "assistant",
        "message": {"id": message_id, "usage": usage, "content": [block]},
    }


def bash(use_id: str, command: str) -> JsonObject:
    return {
        "type": "tool_use",
        "id": use_id,
        "name": "Bash",
        "input": {"command": command},
    }


def read(use_id: str) -> JsonObject:
    return {
        "type": "tool_use",
        "id": use_id,
        "name": "Read",
        "input": {"file_path": "/a"},
    }


def tool_result(use_id: str) -> JsonObject:
    return {
        "type": "user",
        "message": {"content": [{"type": "tool_result", "tool_use_id": use_id}]},
    }


def write_transcript(path: Path, lines: list[JsonObject], filler: int = 0) -> None:
    """Writes a transcript, after `filler` bytes of older lines when asked."""
    path.parent.mkdir(parents=True, exist_ok=True)
    old = model_call("m0", 1_000, bash("toolu_00", "make old")) if filler else []
    text = "".join(json.dumps(line) + "\n" for line in old)
    text += json.dumps({"type": "user", "pad": "x" * filler}) + "\n" if filler else ""
    _ = path.write_text(text + "".join(json.dumps(line) + "\n" for line in lines))
