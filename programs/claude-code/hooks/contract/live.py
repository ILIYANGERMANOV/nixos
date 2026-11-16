"""`just probe-agents-hooks --live`: the hook surface the `state` epic relies
on, proved against the real model in auto mode.

One `claude -p --model haiku` run in a throwaway repo, with the normal login,
types `/probe-live`. That skill has the lead call a second skill, run a Bash
command a hook denies, spawn a subagent that spawns its own, and spawn one in
the background. A recording hook logs every event, hands each subagent a
marker as additionalContext and denies the tagged command. Pure checks over
the hook payloads and the transcripts they name then prove each event fired
with the fields our adapter parses, and that the marker and the deny reason
reached the model: found in what the client sent it, not in what it echoed.
"""

import json
import os
import shlex
import sys
import tempfile
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import cast

from client import ClaudeFailedError, claude, read_jsonl
from model import Json, Payload

CHILD = "probe-child"
GRANDCHILD = "probe-grandchild"
COMMAND_SKILL = "probe-live"
CALLED_SKILL = "probe-skill"
SKILL_ARGS = "PROBE-SKILL-ARGS"
DENY_TAG = "PROBE-DENY-TAG"
DENY_REASON = "PROBE-DENY-REASON"
CONTEXT_MARKER = "PROBE-CONTEXT-MARKER"
# The login's, and nothing of the calling session: run from inside Claude
# Code, its CLAUDE_CODE_* variables change how the nested client spawns.
PASSED_ENV = ("PATH", "HOME", "USER", "CLAUDE_CONFIG_DIR")
# Three subagents on haiku take about a minute; the slack is for a slow API.
TIMEOUT_SECONDS = 600

# What claude_adapter.py's parse_claude and parse_agent read from each event
# they parse, and from a subagent's.
ADAPTER_FIELDS: dict[str, tuple[str, ...]] = {
    "SessionStart": ("hook_event_name", "session_id", "cwd", "source"),
    "SubagentStart": ("hook_event_name", "session_id", "cwd"),
    "UserPromptExpansion": ("hook_event_name", "session_id", "cwd", "command_name"),
    "PreToolUse": (
        "hook_event_name",
        "session_id",
        "cwd",
        "tool_name",
        "tool_input",
        "transcript_path",
        "tool_use_id",
    ),
    "PostToolUse": (
        "hook_event_name",
        "session_id",
        "cwd",
        "tool_name",
        "tool_input",
        "tool_response",
        "transcript_path",
    ),
}
SUBAGENT_FIELDS = ("agent_id", "agent_type")
# The lead's events carry no agent_type.
DEPTHS = {CHILD: 1, GRANDCHILD: 2}

# The lead's script. It names no marker and no deny reason: only a hook puts
# those where the model can see them. Each spawn states run_in_background:
# Claude Code 2.1.314 runs a lead's Agent call that leaves it out in the
# background.
COMMAND_SKILL_BODY = f"""\
---
name: {COMMAND_SKILL}
description: The live hook probe's script. Only a person runs it.
disable-model-invocation: true
---
Do these steps in order, one tool call each, then reply `probe done`.

1. Call the Skill tool with skill `{CALLED_SKILL}` and args `{SKILL_ARGS}`.
2. Run the Bash command `echo {DENY_TAG}`. A hook denies it on purpose: do not retry it.
3. Spawn an Agent with subagent_type `{CHILD}`, run_in_background false, and the
   prompt: "Spawn one Agent with subagent_type `{GRANDCHILD}`, run_in_background
   false, and the prompt 'Hand back the word done.', then hand back the word done."
4. Spawn an Agent with subagent_type `{CHILD}`, run_in_background true, and the
   prompt "Hand back the word done.". Wait for its hand-back before you reply.
"""
CALLED_SKILL_BODY = f"""\
---
name: {CALLED_SKILL}
description: Part of the live hook probe. Call it only when told to.
---
Go on with your next step.
"""
SUBAGENT_PROMPT = (
    "You are a hook probe subagent. Do exactly what your task says and nothing"
    " else, then call SubagentHandback with a one-line message."
)
AGENTS = {
    CHILD: {
        "description": "The live hook probe's depth-1 subagent",
        "prompt": SUBAGENT_PROMPT,
        "tools": ["Agent", "Bash", "SubagentHandback"],
    },
    GRANDCHILD: {
        "description": "The live hook probe's depth-2 subagent",
        "prompt": SUBAGENT_PROMPT,
        "tools": ["Bash", "SubagentHandback"],
    },
}


@dataclass(frozen=True, slots=True)
class Check:
    name: str
    depth: int
    passed: bool
    detail: str


def probe(version: str, hook: list[str]) -> int:
    """Runs the live probe and prints its table and summary line. `hook` is
    the argv that runs `respond` on a payload, less the log path."""
    with tempfile.TemporaryDirectory(prefix="probe-agents-hooks-live-") as work:
        try:
            events = run(Path(work), hook)
        except ClaudeFailedError as error:
            print(error, file=sys.stderr)
            print(f"probe-agents-hooks --live: claude-code {version} FAIL")
            return 1
    results = checks(events, read_transcripts(events))
    passed = all(result.passed for result in results)
    print(table(results))
    print(
        f"probe-agents-hooks --live: claude-code {version} {'PASS' if passed else 'FAIL'}"
    )
    return 0 if passed else 1


def run(work: Path, hook: list[str]) -> list[Payload]:
    repo, log, settings = work / "repo", work / "hooks.jsonl", work / "settings.json"
    for skill, body in (
        (COMMAND_SKILL, COMMAND_SKILL_BODY),
        (CALLED_SKILL, CALLED_SKILL_BODY),
    ):
        (repo / ".claude" / "skills" / skill).mkdir(parents=True)
        _ = (repo / ".claude" / "skills" / skill / "SKILL.md").write_text(body)
    _ = settings.write_text(json.dumps(recording_settings([*hook, str(log)])))
    # The person's own environment and login: the live probe costs a few
    # haiku turns on their account.
    _ = claude(
        [
            "claude",
            "-p",
            "--model",
            "haiku",
            "--output-format",
            "json",
            "--permission-mode",
            "auto",
            "--setting-sources",
            "project",
            "--settings",
            str(settings),
            "--agents",
            json.dumps(AGENTS),
            "--",
            f"/{COMMAND_SKILL}",
        ],
        repo,
        {key: os.environ[key] for key in PASSED_ENV if key in os.environ},
        TIMEOUT_SECONDS,
    )
    return read_jsonl(log)


def recording_settings(hook: list[str]) -> Json:
    hooks: list[Json] = [{"type": "command", "command": shlex.join(hook)}]
    every: list[Json] = [{"hooks": hooks}]
    return {
        "hooks": dict.fromkeys(
            (
                "SessionStart",
                "UserPromptExpansion",
                "PreToolUse",
                "PostToolUse",
                "SubagentStart",
                "SubagentStop",
            ),
            every,
        )
    }


def read_transcripts(events: list[Payload]) -> dict[str, str]:
    """Every transcript an event names, by path; one not on disk is left out,
    and the check that needs it fails."""
    paths = {
        path
        for event in events
        for key in ("transcript_path", "agent_transcript_path")
        if isinstance(path := event.get(key), str)
    }
    return {path: Path(path).read_text() for path in paths if Path(path).is_file()}


def respond(payload: Payload) -> Json:
    """The live hook's answer: a marker naming each subagent's type as its
    additionalContext, and a deny for the tagged Bash command."""
    match payload:
        case {"hook_event_name": "SubagentStart", "agent_type": str(agent_type)}:
            return {
                "hookSpecificOutput": {
                    "hookEventName": "SubagentStart",
                    "additionalContext": marker(agent_type),
                }
            }
        case {
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": str(command)},
        } if DENY_TAG in command:
            return {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": DENY_REASON,
                }
            }
        case _:
            return {}


def marker(agent_type: str) -> str:
    return f"{CONTEXT_MARKER}-{agent_type}"


def table(results: list[Check]) -> str:
    rows = [
        f"| {result.name} | {result.depth} | {'pass' if result.passed else 'FAIL'} | {result.detail} |"
        for result in results
    ]
    return "\n".join(
        ["| check | depth | result | detail |", "|---|---|---|---|", *rows]
    )


@dataclass(frozen=True, slots=True)
class Passed:
    """What a check found: its row's detail."""

    detail: str


@dataclass(frozen=True, slots=True)
class Missing:
    """What a check looked for and did not find: its failure's detail."""

    detail: str


def checks(events: list[Payload], transcripts: dict[str, str]) -> list[Check]:
    """The live probe's verdict on one run: its hook payloads in firing order
    and the transcripts they name. Ids are matched by value across events."""
    indexed = list(enumerate(events))

    def child() -> str | Missing:
        return then(
            spawned(indexed, None, CHILD, background=False),
            lambda spawn: spawn.agent_id,
        )

    def grandchild() -> str | Missing:
        return then(
            child(),
            lambda parent: then(
                spawned(indexed, parent, GRANDCHILD, background=False),
                lambda spawn: spawn.agent_id,
            ),
        )

    return [
        verdict(
            "UserPromptExpansion for the typed skill", 0, lambda: expansion(indexed)
        ),
        verdict("PreToolUse Skill carries skill and args", 0, lambda: skill(indexed)),
        verdict(
            "foreground spawn: Pre, SubagentStart, SubagentStop, Post",
            1,
            lambda: foreground(indexed, None, CHILD),
        ),
        verdict(
            "foreground spawn: Pre, SubagentStart, SubagentStop, Post",
            2,
            lambda: then(
                child(), lambda parent: foreground(indexed, parent, GRANDCHILD)
            ),
        ),
        verdict(
            "background spawn: Post at launch, before SubagentStop",
            1,
            lambda: background(indexed),
        ),
        verdict(
            "SubagentStart additionalContext reaches the subagent",
            1,
            lambda: then(
                child(),
                lambda agent_id: delivered(indexed, transcripts, agent_id, CHILD),
            ),
        ),
        verdict(
            "SubagentStart additionalContext reaches the subagent",
            2,
            lambda: then(
                grandchild(),
                lambda agent_id: delivered(indexed, transcripts, agent_id, GRANDCHILD),
            ),
        ),
        verdict(
            "PreToolUse deny reason reaches the agent",
            0,
            lambda: denied(indexed, transcripts),
        ),
        *(
            verdict(
                "every event carries the adapter's fields",
                depth,
                lambda depth=depth: adapter_fields(indexed, depth),
            )
            for depth in (0, 1, 2)
        ),
    ]


def verdict(name: str, depth: int, verify: Callable[[], Passed | Missing]) -> Check:
    match verify():
        case Passed(detail):
            return Check(name, depth, passed=True, detail=detail)
        case Missing(detail):
            return Check(name, depth, passed=False, detail=detail)


def then[T, U](found: T | Missing, step: Callable[[T], U | Missing]) -> U | Missing:
    """`step` on what a lookup found; what it did not find passes through."""
    match found:
        case Missing():
            return found
        case _:
            return step(found)


type Indexed = list[tuple[int, Payload]]


@dataclass(frozen=True, slots=True)
class Found:
    """An event and its position in firing order."""

    index: int
    event: Payload


def expansion(events: Indexed) -> Passed | Missing:
    match first(
        events,
        f"UserPromptExpansion with command_name {COMMAND_SKILL}",
        lambda event: (
            event.get("hook_event_name") == "UserPromptExpansion"
            and event.get("command_name") == COMMAND_SKILL
        ),
    ):
        case Missing() as missing:
            return missing
        case Found(event={"expansion_type": str(kind), "prompt": str(prompt)}) if (
            f"/{COMMAND_SKILL}" in prompt
        ):
            return Passed(f"expansion_type {kind}")
        case Found():
            return Missing(
                f"UserPromptExpansion without expansion_type or a prompt naming /{COMMAND_SKILL}"
            )


def skill(events: Indexed) -> Passed | Missing:
    match first(
        events,
        f"PreToolUse Skill {CALLED_SKILL}",
        lambda event: (
            tool_event(event, "PreToolUse", "Skill")
            and field(event, "tool_input", "skill") == CALLED_SKILL
        ),
    ):
        case Missing() as missing:
            return missing
        case Found(event=event):
            match field(event, "tool_input", "args"):
                case str(args) if args:
                    return Passed(f"args {args}")
                case _:
                    return Missing(f"PreToolUse Skill {CALLED_SKILL} without args")


@dataclass(frozen=True, slots=True)
class Spawn:
    """An Agent call, linked by its tool_use_id from PreToolUse to the
    PostToolUse whose tool_response names the agent it spawned."""

    pre: int
    post: int
    agent_id: str


def spawned(
    events: Indexed, parent: str | None, agent_type: str, *, background: bool
) -> Spawn | Missing:
    """The Agent call of `parent` (None: the lead) spawning `agent_type`."""
    what = f"PreToolUse Agent {agent_type}{' in the background' if background else ''} by {parent or 'the lead'}"
    match first(
        events,
        what,
        lambda event: (
            tool_event(event, "PreToolUse", "Agent")
            and event.get("agent_id") == parent
            and field(event, "tool_input", "subagent_type") == agent_type
            and (field(event, "tool_input", "run_in_background") is True) == background
        ),
    ):
        case Missing() as missing:
            return missing
        case Found(pre, call):
            pass
    match first(
        events,
        f"PostToolUse for the {what}",
        lambda event: (
            tool_event(event, "PostToolUse", "Agent")
            and event.get("tool_use_id") == call.get("tool_use_id")
        ),
    ):
        case Missing() as missing:
            return missing
        case Found(post, result):
            pass
    match field(result, "tool_response", "agentId"):
        case str(agent_id):
            return Spawn(pre, post, agent_id)
        case _:
            return Missing(f"PostToolUse for the {what} without tool_response.agentId")


def foreground(
    events: Indexed, parent: str | None, agent_type: str
) -> Passed | Missing:
    match spawned(events, parent, agent_type, background=False):
        case Missing() as missing:
            return missing
        case Spawn() as spawn:
            pass
    match lifetime(events, spawn.agent_id, agent_type):
        case Missing() as missing:
            return missing
        case (start, stop) if spawn.pre < start < stop < spawn.post:
            return Passed(f"agent {spawn.agent_id}")
        case (start, stop):
            return Missing(
                f"out of order: Pre {spawn.pre}, Start {start}, Stop {stop}, Post {spawn.post}"
            )


def background(events: Indexed) -> Passed | Missing:
    # Post before Stop, not before Start: a background launch's PostToolUse
    # and SubagentStart hooks run at the same moment, so their order races.
    match spawned(events, None, CHILD, background=True):
        case Missing() as missing:
            return missing
        case Spawn() as spawn:
            pass
    match lifetime(events, spawn.agent_id, CHILD):
        case Missing() as missing:
            return missing
        case (start, stop) if spawn.pre < spawn.post < stop and start < stop:
            return Passed(f"agent {spawn.agent_id}")
        case (start, stop):
            return Missing(
                f"out of order: Pre {spawn.pre}, Post {spawn.post}, Start {start}, Stop {stop}"
            )


def lifetime(
    events: Indexed, agent_id: str, agent_type: str
) -> tuple[int, int] | Missing:
    """The positions of an agent's SubagentStart, which must name its type,
    and of its first SubagentStop."""
    match first(
        events,
        f"SubagentStart {agent_type} {agent_id}",
        lambda event: (
            event.get("hook_event_name") == "SubagentStart"
            and event.get("agent_id") == agent_id
            and event.get("agent_type") == agent_type
        ),
    ):
        case Missing() as missing:
            return missing
        case Found(start):
            return then(
                first(events, f"SubagentStop {agent_id}", stopped(agent_id)),
                lambda stop: (start, stop.index),
            )


def delivered(
    events: Indexed, transcripts: dict[str, str], agent_id: str, agent_type: str
) -> Passed | Missing:
    match first(events, f"SubagentStop {agent_id}", stopped(agent_id)):
        case Missing() as missing:
            return missing
        case Found(event={"agent_transcript_path": str(path)}) if any(
            marker(agent_type) in message for message in sent(transcripts.get(path, ""))
        ):
            return Passed(f"{marker(agent_type)} sent to it")
        case Found():
            return Missing(
                f"{marker(agent_type)} in no message of {agent_id}'s transcript"
            )


def denied(events: Indexed, transcripts: dict[str, str]) -> Passed | Missing:
    match first(
        events,
        f"the lead's PreToolUse Bash `echo {DENY_TAG}`",
        lambda event: (
            tool_event(event, "PreToolUse", "Bash")
            and "agent_id" not in event
            and DENY_TAG in str(field(event, "tool_input", "command"))
        ),
    ):
        case Missing() as missing:
            return missing
        case Found(event=call):
            pass
    tool_use_id = call.get("tool_use_id")
    ran = any(
        tool_event(event, "PostToolUse", "Bash")
        and event.get("tool_use_id") == tool_use_id
        for _, event in events
    )
    match call.get("transcript_path"):
        case _ if ran:
            return Missing(f"the denied call {tool_use_id} ran: it has a PostToolUse")
        case str(path) if any(
            DENY_REASON in message and f'"{tool_use_id}"' in message
            for message in sent(transcripts.get(path, ""))
        ):
            return Passed(f"{DENY_REASON} in the result of {tool_use_id}")
        case _:
            return Missing(
                f"{DENY_REASON} in no message of the lead transcript holding {tool_use_id}"
            )


def sent(transcript: str) -> list[str]:
    """Each transcript line's `message`, as JSON text: what went to or came
    from the model. The other lines are the client's bookkeeping, the hooks'
    raw output among them, so a token there proves no delivery."""
    lines = (cast("Payload", json.loads(line)) for line in transcript.splitlines())
    return [
        json.dumps(message)
        for line in lines
        if (message := line.get("message")) is not None
    ]


def adapter_fields(events: Indexed, depth: int) -> Passed | Missing:
    """Every event the adapter parses, at `depth`, carries what it reads."""
    at_depth = [
        event
        for _, event in events
        if str(event.get("hook_event_name")) in ADAPTER_FIELDS
        and depth_of(event) == depth
    ]
    lacking = sorted(
        {
            f"{event.get('hook_event_name')} {event.get('tool_name', '')} lacks {key}"
            for event in at_depth
            for key in required(event, depth)
            if key not in event
        }
    )
    match (at_depth, lacking):
        case ([], _):
            return Missing(f"no event the adapter parses at depth {depth}")
        case (_, []):
            return Passed(f"{len(at_depth)} events")
        case _:
            return Missing("; ".join(lacking))


def depth_of(event: Payload) -> int:
    return DEPTHS.get(str(event.get("agent_type")), 0)


def required(event: Payload, depth: int) -> Iterable[str]:
    fields = ADAPTER_FIELDS[str(event.get("hook_event_name"))]
    return (*fields, *SUBAGENT_FIELDS) if depth > 0 else fields


def first(
    events: Indexed, what: str, matches: Callable[[Payload], bool]
) -> Found | Missing:
    return next(
        (Found(index, event) for index, event in events if matches(event)),
        Missing(f"no {what}"),
    )


def stopped(agent_id: str) -> Callable[[Payload], bool]:
    return lambda event: (
        event.get("hook_event_name") == "SubagentStop"
        and event.get("agent_id") == agent_id
    )


def tool_event(event: Payload, name: str, tool: str) -> bool:
    return event.get("hook_event_name") == name and event.get("tool_name") == tool


def field(event: Payload, key: str, inner: str) -> Json:
    match event.get(key):
        case {**fields}:
            return fields.get(inner)
        case _:
            return None
