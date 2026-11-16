"""The live probe's verdict over one recorded run, healthy and broken each way
a newer client could break the hook surface. The run itself needs the real
model: `just probe-agents-hooks --live`.

fixtures/live-run.json is one real run on Claude Code 2.1.314 as live.run
returned it, its transcripts cut to the lines holding a probe marker or the
deny reason."""

import json
from collections.abc import Callable
from pathlib import Path
from typing import cast

import pytest
from live import Check, checks, respond
from model import Payload

type Run = tuple[list[Payload], dict[str, str]]

FIXTURE = Path(__file__).parent / "fixtures" / "live-run.json"
FOREGROUND = "foreground spawn: Pre, SubagentStart, SubagentStop, Post"
BACKGROUND = "background spawn: Post at launch, before SubagentStop"
CONTEXT = "SubagentStart additionalContext reaches the subagent"
DENY = "PreToolUse deny reason reaches the agent"
FIELDS = "every event carries the adapter's fields"


def test_the_recorded_run_passes_every_check() -> None:
    events, transcripts = recorded()

    assert failed(checks(events, transcripts)) == []


def no_expansion(events: list[Payload], transcripts: dict[str, str]) -> Run:
    return without(events, is_event("UserPromptExpansion")), transcripts


def no_skill_args(events: list[Payload], transcripts: dict[str, str]) -> Run:
    return edited(
        events, is_tool("PreToolUse", "Skill"), lambda e: drop_input(e, "args")
    ), transcripts


def no_child_start(events: list[Payload], transcripts: dict[str, str]) -> Run:
    return without(events, is_start("probe-child")), transcripts


def mismatched_grandchild_id(events: list[Payload], transcripts: dict[str, str]) -> Run:
    return edited(
        events, is_start("probe-grandchild"), lambda e: {**e, "agent_id": "a0"}
    ), transcripts


def no_background_agent_id(events: list[Payload], transcripts: dict[str, str]) -> Run:
    return edited(
        events, is_background_post, lambda e: drop_response(e, "agentId")
    ), transcripts


def background_post_after_stop(
    events: list[Payload], transcripts: dict[str, str]
) -> Run:
    post = next(event for event in events if is_background_post(event))
    return [*without(events, is_background_post), post], transcripts


def context_only_in_hook_output(
    events: list[Payload], transcripts: dict[str, str]
) -> Run:
    child = transcript_of(events, "probe-child")
    return events, {**transcripts, child: hook_lines(transcripts[child])}


def no_deny_reason(events: list[Payload], transcripts: dict[str, str]) -> Run:
    lead = lead_transcript(events)
    return events, {
        **transcripts,
        lead: transcripts[lead].replace("PROBE-DENY-REASON", ""),
    }


def denied_call_ran(events: list[Payload], transcripts: dict[str, str]) -> Run:
    call = next(event for event in events if is_denied(event))
    ran: Payload = {
        **call,
        "hook_event_name": "PostToolUse",
        "tool_response": {"stdout": "PROBE-DENY-TAG", "stderr": ""},
    }
    return [*events, ran], transcripts


def no_tool_use_id_at_depth_2(
    events: list[Payload], transcripts: dict[str, str]
) -> Run:
    return edited(
        events,
        lambda e: (
            is_tool("PreToolUse", "SubagentHandback")(e)
            and e.get("agent_type") == "probe-grandchild"
        ),
        lambda e: omit(e, "tool_use_id"),
    ), transcripts


@pytest.mark.parametrize(
    ("breakage", "check"),
    [
        (no_expansion, ("UserPromptExpansion for the typed skill", 0)),
        (no_skill_args, ("PreToolUse Skill carries skill and args", 0)),
        (no_child_start, (FOREGROUND, 1)),
        (mismatched_grandchild_id, (FOREGROUND, 2)),
        (no_background_agent_id, (BACKGROUND, 1)),
        (background_post_after_stop, (BACKGROUND, 1)),
        (context_only_in_hook_output, (CONTEXT, 1)),
        (no_deny_reason, (DENY, 0)),
        (denied_call_ran, (DENY, 0)),
        (no_tool_use_id_at_depth_2, (FIELDS, 2)),
    ],
)
def test_a_broken_run_fails_exactly_its_check(
    breakage: Callable[[list[Payload], dict[str, str]], Run], check: tuple[str, int]
) -> None:
    events, transcripts = breakage(*recorded())

    assert failed(checks(events, transcripts)) == [check]


def test_the_hook_hands_each_subagent_a_marker_naming_its_type() -> None:
    start: Payload = {"hook_event_name": "SubagentStart", "agent_type": "probe-child"}

    assert respond(start) == {
        "hookSpecificOutput": {
            "hookEventName": "SubagentStart",
            "additionalContext": "PROBE-CONTEXT-MARKER-probe-child",
        }
    }


def test_the_hook_denies_the_tagged_bash_command_with_its_reason() -> None:
    call: Payload = {
        "hook_event_name": "PreToolUse",
        "tool_name": "Bash",
        "tool_input": {"command": "echo PROBE-DENY-TAG"},
    }

    assert respond(call) == {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": "PROBE-DENY-REASON",
        }
    }


def test_the_hook_leaves_any_other_call_alone() -> None:
    call: Payload = {
        "hook_event_name": "PreToolUse",
        "tool_name": "Bash",
        "tool_input": {"command": "echo hi"},
    }

    assert respond(call) == {}


def recorded() -> Run:
    fixture = cast("Payload", json.loads(FIXTURE.read_text()))
    return (
        cast("list[Payload]", fixture["events"]),
        cast("dict[str, str]", fixture["transcripts"]),
    )


def failed(results: list[Check]) -> list[tuple[str, int]]:
    return [(result.name, result.depth) for result in results if not result.passed]


def without(events: list[Payload], matches: Callable[[Payload], bool]) -> list[Payload]:
    """The events less the first that matches."""
    index = next(i for i, event in enumerate(events) if matches(event))
    return [*events[:index], *events[index + 1 :]]


def edited(
    events: list[Payload],
    matches: Callable[[Payload], bool],
    edit: Callable[[Payload], Payload],
) -> list[Payload]:
    """The events with the first that matches edited."""
    index = next(i for i, event in enumerate(events) if matches(event))
    return [*events[:index], edit(events[index]), *events[index + 1 :]]


def is_event(name: str) -> Callable[[Payload], bool]:
    return lambda event: event.get("hook_event_name") == name


def is_tool(name: str, tool: str) -> Callable[[Payload], bool]:
    return lambda event: is_event(name)(event) and event.get("tool_name") == tool


def is_start(agent_type: str) -> Callable[[Payload], bool]:
    return lambda event: (
        is_event("SubagentStart")(event) and event.get("agent_type") == agent_type
    )


def is_background_post(event: Payload) -> bool:
    return (
        is_tool("PostToolUse", "Agent")(event)
        and tool_input(event).get("run_in_background") is True
    )


def is_denied(event: Payload) -> bool:
    return is_tool("PreToolUse", "Bash")(event) and "PROBE-DENY-TAG" in str(
        tool_input(event).get("command")
    )


def transcript_of(events: list[Payload], agent_type: str) -> str:
    stop = next(
        event
        for event in events
        if is_event("SubagentStop")(event) and event.get("agent_type") == agent_type
    )
    return str(stop["agent_transcript_path"])


def lead_transcript(events: list[Payload]) -> str:
    return str(next(event for event in events if is_denied(event))["transcript_path"])


def hook_lines(transcript: str) -> str:
    """Only the transcript's hook bookkeeping, which echoes the hook's output
    but is not sent to the model."""
    return "".join(
        f"{line}\n" for line in transcript.splitlines() if '"hook_success"' in line
    )


def drop_input(event: Payload, key: str) -> Payload:
    return {**event, "tool_input": omit(tool_input(event), key)}


def drop_response(event: Payload, key: str) -> Payload:
    return {
        **event,
        "tool_response": omit(cast("Payload", event["tool_response"]), key),
    }


def omit(fields: Payload, key: str) -> Payload:
    return {k: v for k, v in fields.items() if k != key}


def tool_input(event: Payload) -> Payload:
    return cast("Payload", event["tool_input"])
