"""Finds and reads the transcript of the agent a hook fired in, for the guards."""

from pathlib import Path

from hook_event import Json, parse_json


def own_transcript(event: Json) -> Path:
    """The transcript of the agent that made the call.

    `transcript_path` always names the main session's. A subagent's, at any
    depth, sits under the session's own directory, named after its `agent_id`.
    """
    match event:
        case {"transcript_path": str(path), "agent_id": str(agent_id)}:
            subagents = Path(path).with_suffix("") / "subagents"
            return subagents / f"agent-{agent_id}.jsonl"
        case {"transcript_path": str(path)}:
            return Path(path)
        case _:
            raise ValueError("no transcript_path")


def in_subagent(event: Json) -> bool:
    match event:
        case {"agent_id": _}:
            return True
        case _:
            return False


def parse_line(line: bytes) -> Json:
    """The line's JSON, None for a partial line of a tail or a running write."""
    try:
        return parse_json(line)
    except ValueError:
        return None
