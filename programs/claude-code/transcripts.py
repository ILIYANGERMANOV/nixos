"""Finds and reads the transcript of the agent a hook fired in, for the guards."""

import json
from pathlib import Path

# Past this context an agent hands a long check back: a wait over the 5 minute
# cache costs more in rewrites than a fresh small agent running the check.
CHECK_HANDBACK_AT = 60_000


def own_transcript(event: dict) -> Path:
    """The transcript of the agent that made the call.

    `transcript_path` always names the main session's. A subagent's, at any
    depth, sits under the session's own directory, named after its `agent_id`.
    """
    main = Path(event["transcript_path"])
    match event.get("agent_id"):
        case None:
            return main
        case agent_id:
            return main.with_suffix("") / "subagents" / f"agent-{agent_id}.jsonl"


def parse_line(line: bytes) -> object:
    """The line's JSON, None for a partial line of a tail or a running write."""
    try:
        return json.loads(line)
    except ValueError:
        return None
