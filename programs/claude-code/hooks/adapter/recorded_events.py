"""What the adapter tests share: the hook payloads one real live probe run
(contract/live.py) recorded, as Claude Code sent them."""

import json
from pathlib import Path
from typing import cast

from agent_hook import JsonObject

_LIVE_RUN = cast(
    "list[JsonObject]",
    json.loads(
        (
            Path(__file__).parents[1] / "contract" / "fixtures" / "live-run.json"
        ).read_text()
    )["events"],
)


def recorded_all(event: str) -> list[JsonObject]:
    """Every `event` (a `hook_event_name`) the live probe recorded."""
    return [e for e in _LIVE_RUN if e["hook_event_name"] == event]


def recorded(event: str) -> JsonObject:
    """The first `event` the live probe recorded."""
    return recorded_all(event)[0]
