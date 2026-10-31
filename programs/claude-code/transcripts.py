"""Finds and reads the transcript of the agent a hook fired in, for the guards."""

from pathlib import Path

from hook_event import (
    Agent,
    Caller,
    Json,
    MainAgent,
    Subagent,
    UnnamedSubagent,
    parse_json,
)


def own_transcript(caller: Caller) -> Path:
    """The transcript of the agent that made the call.

    `transcript_path` always names the main session's. A subagent's, at any
    depth, sits under the session's own directory, named after its `agent_id`.
    """
    path = caller.transcript_path
    if path is None:
        raise ValueError("no transcript_path")
    match caller.agent:
        case Subagent(agent_id):
            return path.with_suffix("") / "subagents" / f"agent-{agent_id}.jsonl"
        case MainAgent() | UnnamedSubagent():
            return path


def in_subagent(agent: Agent) -> bool:
    return not isinstance(agent, MainAgent)


def parse_line(line: bytes) -> Json:
    """The line's JSON, None for a partial line of a tail or a running write."""
    try:
        return parse_json(line)
    except ValueError:
        return None
