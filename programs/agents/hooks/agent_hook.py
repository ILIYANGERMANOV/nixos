"""The neutral hook contract, the same for every agent, and the dispatcher.

A hook is a program. It reads one event as JSON on stdin and prints one result
as JSON on stdout, or nothing, which allows:

    stdin:  {event, tool, input, output, cwd, session, agent: {id, role} | null, source}
    stdout: {decision: allow | deny, reason, context, updatedInput}

An agent's backend translates its own hook format to an `Event`, hands it to
`dispatch` with the hooks declared for that event, and translates the `Result`
back. So every backend runs the same hooks in the same order with the same
outcome, whatever its own hooks do with order or parallelism.

The names an event, tool or source can take are `vocabulary.json`'s, which the
Nix declarations read too; a test holds the enums below to it.
"""

import json
import subprocess
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, replace
from enum import StrEnum
from pathlib import Path
from typing import NewType, cast

# What `json.loads` can return, spelled out because typeshed says Any.
type Json = None | bool | int | float | str | list[Json] | dict[str, Json]
type JsonObject = dict[str, Json]

SessionId = NewType("SessionId", str)
AgentId = NewType("AgentId", str)
Role = NewType("Role", str)
HookName = NewType("HookName", str)


class EventName(StrEnum):
    SESSION_START = "sessionStart"
    BEFORE_TOOL = "beforeTool"
    AFTER_TOOL = "afterTool"


class Tool(StrEnum):
    SHELL = "shell"
    READ = "read"
    EDIT = "edit"
    WRITE = "write"
    DELEGATE = "delegate"
    HANDBACK = "handback"
    ASK = "ask"
    WEB = "web"
    SKILL = "skill"


class Source(StrEnum):
    """Why a session started: a new one, a resumed one, or one just compacted."""

    STARTUP = "startup"
    RESUME = "resume"
    COMPACT = "compact"


@dataclass(frozen=True, slots=True)
class Agent:
    """The subagent making the call; the lead is no agent. `role` is its type."""

    id: AgentId
    role: Role


@dataclass(frozen=True, slots=True)
class SessionStart:
    session: SessionId
    cwd: Path
    agent: Agent | None
    source: Source


@dataclass(frozen=True, slots=True)
class BeforeTool:
    session: SessionId
    cwd: Path
    agent: Agent | None
    tool: Tool
    input: JsonObject


@dataclass(frozen=True, slots=True)
class AfterTool:
    session: SessionId
    cwd: Path
    agent: Agent | None
    tool: Tool
    input: JsonObject
    output: Json


type Event = SessionStart | BeforeTool | AfterTool


@dataclass(frozen=True, slots=True)
class Allow:
    """The call goes on. Only a beforeTool hook may rewrite its input."""

    context: str | None = None
    updated_input: JsonObject | None = None


@dataclass(frozen=True, slots=True)
class Deny:
    """The call does not happen. Only a beforeTool hook may deny."""

    reason: str
    context: str | None = None


type Result = Allow | Deny


@dataclass(frozen=True, slots=True)
class EveryTool:
    """A hook declared with no tools: it sees every tool's calls."""


@dataclass(frozen=True, slots=True)
class Hook:
    name: HookName
    tools: frozenset[Tool] | EveryTool
    command: tuple[str, ...]


# The declared hooks, each event's in the order they run.
type Manifest = Mapping[EventName, tuple[Hook, ...]]

type Runner = Callable[[Hook, Event], Result]

RESULT_FIELDS = frozenset({"decision", "reason", "context", "updatedInput"})


def dispatch(hooks: Sequence[Hook], event: Event, run: Runner) -> Result:
    """Runs the hooks that match `event` in order and folds their results.

    Each hook sees the input the one before it rewrote. The first deny stops
    the chain: the call it denies never happens, so no later hook sees it.
    """
    result: Result = Allow()
    for hook in hooks:
        if not matches(hook, event):
            continue
        result = combine(result, run(hook, threaded(event, result)))
        match result:
            case Deny():
                return result
            case Allow():
                pass
    return result


def combine(first: Result, second: Result) -> Result:
    """The results' monoid, `Allow()` its identity: deny wins, contexts and
    reasons join in order, and the later rewrite of the input wins."""
    context = joined(first.context, second.context)
    match first, second:
        case Allow(), Allow():
            updated = (
                second.updated_input
                if second.updated_input is not None
                else first.updated_input
            )
            return Allow(context, updated)
        case (Allow(), Deny(reason=reason)) | (Deny(reason=reason), Allow()):
            return Deny(reason, context)
        case Deny(reason=one), Deny(reason=other):
            return Deny(f"{one}\n{other}", context)


def joined(first: str | None, second: str | None) -> str | None:
    match first, second:
        case None, _:
            return second
        case _, None:
            return first
        case _:
            return f"{first}\n\n{second}"


def matches(hook: Hook, event: Event) -> bool:
    match event:
        case SessionStart():
            return True
        case BeforeTool(tool=tool) | AfterTool(tool=tool):
            match hook.tools:
                case EveryTool():
                    return True
                case frozenset() as tools:
                    return tool in tools


def threaded(event: Event, result: Result) -> Event:
    """The event the next hook sees: the input the chain has rewritten so far."""
    match event, result:
        case BeforeTool(), Allow(updated_input=dict() as updated):
            return replace(event, input=updated)
        case _:
            return event


def run_hook(hook: Hook, event: Event) -> Result:
    """Runs one hook. One that fails, or prints what the contract does not
    allow, never blocks the call: its error becomes context, so the agent
    learns of it."""
    try:
        done = subprocess.run(
            hook.command,
            input=emit_event(event),
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as error:
        return told(hook, str(error))
    if done.returncode != 0:
        lines = done.stderr.strip().splitlines()
        return told(hook, f"exit {done.returncode}: {lines[-1] if lines else ''}")
    try:
        return parse_result(event, done.stdout)
    except ValueError as error:
        return told(hook, f"bad output: {error}")


def told(hook: Hook, error: str) -> Result:
    return Allow(context=f"hook {hook.name}: {error}")


def hooks_for(manifest: Manifest, event: Event) -> tuple[Hook, ...]:
    return manifest.get(event_name(event), ())


def event_name(event: Event) -> EventName:
    match event:
        case SessionStart():
            return EventName.SESSION_START
        case BeforeTool():
            return EventName.BEFORE_TOOL
        case AfterTool():
            return EventName.AFTER_TOOL


def parse_manifest(text: str) -> Manifest:
    """The declarations Nix wrote: event -> [{name, tools, command}], in order."""
    match parse_json(text):
        case dict() as events:
            return {
                EventName(name): tuple(parse_hook(hook) for hook in as_list(hooks))
                for name, hooks in events.items()
            }
        case _:
            raise ValueError("the manifest is not a JSON object")


def parse_hook(hook: Json) -> Hook:
    match hook:
        case {"name": str(name), "tools": None, "command": [str(), *_] as command}:
            return Hook(HookName(name), EveryTool(), parse_command(command))
        case {"name": str(name), "tools": [*tools], "command": [str(), *_] as command}:
            return Hook(
                HookName(name),
                frozenset(Tool(as_str(tool)) for tool in tools),
                parse_command(command),
            )
        case _:
            raise ValueError(f"not a hook declaration: {hook!r}")


def parse_command(command: list[Json]) -> tuple[str, ...]:
    return tuple(as_str(arg) for arg in command)


def parse_event(text: str) -> Event:
    """What a hook reads on stdin. An unknown event, tool or source is an error."""
    match parse_json(text):
        case {
            "event": "sessionStart",
            "session": str(session),
            "cwd": str(cwd),
            "agent": agent,
            "source": str(source),
        }:
            return SessionStart(
                SessionId(session), Path(cwd), parse_agent(agent), Source(source)
            )
        case {
            "event": "beforeTool",
            "session": str(session),
            "cwd": str(cwd),
            "agent": agent,
            "tool": str(tool),
            "input": dict() as tool_input,
        }:
            return BeforeTool(
                SessionId(session),
                Path(cwd),
                parse_agent(agent),
                Tool(tool),
                tool_input,
            )
        case {
            "event": "afterTool",
            "session": str(session),
            "cwd": str(cwd),
            "agent": agent,
            "tool": str(tool),
            "input": dict() as tool_input,
            "output": output,
        }:
            return AfterTool(
                SessionId(session),
                Path(cwd),
                parse_agent(agent),
                Tool(tool),
                tool_input,
                output,
            )
        case _:
            raise ValueError("not a sessionStart, beforeTool or afterTool event")


def parse_agent(agent: Json) -> Agent | None:
    match agent:
        case None:
            return None
        case {"id": str(agent_id), "role": str(role)}:
            return Agent(AgentId(agent_id), Role(role))
        case _:
            raise ValueError(f"not an agent: {agent!r}")


def emit_event(event: Event) -> str:
    common: JsonObject = {
        "event": event_name(event).value,
        "session": event.session,
        "cwd": str(event.cwd),
        "agent": emit_agent(event.agent),
    }
    match event:
        case SessionStart(source=source):
            return json.dumps(common | {"source": source.value})
        case BeforeTool(tool=tool, input=tool_input):
            return json.dumps(common | {"tool": tool.value, "input": tool_input})
        case AfterTool(tool=tool, input=tool_input, output=output):
            return json.dumps(
                common | {"tool": tool.value, "input": tool_input, "output": output}
            )


def emit_agent(agent: Agent | None) -> Json:
    match agent:
        case None:
            return None
        case Agent(id=agent_id, role=role):
            return {"id": agent_id, "role": role}


def parse_result(event: Event, text: str) -> Result:
    """What a hook printed. Empty allows; a field the event cannot honour, such
    as a deny after the tool ran, is an error rather than dropped."""
    if not text.strip():
        return Allow()
    fields = result_fields(text)
    context = optional_str(fields, "context")
    rewrites = isinstance(event, BeforeTool)
    match fields.get("decision", "allow"):
        case "deny":
            return parse_deny(fields, context, rewrites=rewrites)
        case "allow":
            return parse_allow(fields, context, rewrites=rewrites)
        case decision:
            raise ValueError(f"unknown decision {decision!r}")


def parse_deny(fields: JsonObject, context: str | None, *, rewrites: bool) -> Deny:
    match rewrites, fields.get("updatedInput"):
        case False, _:
            raise ValueError("only beforeTool may deny")
        case True, None:
            return Deny(parse_reason(fields), context)
        case True, _:
            raise ValueError("a deny rewrites no input")


def parse_allow(fields: JsonObject, context: str | None, *, rewrites: bool) -> Allow:
    if "reason" in fields:
        raise ValueError("only a deny has a reason")
    match fields.get("updatedInput"):
        case None:
            return Allow(context)
        case dict() as updated if rewrites:
            return Allow(context, updated)
        case dict():
            raise ValueError("only beforeTool may rewrite the input")
        case _:
            raise ValueError("updatedInput is not an object")


def result_fields(text: str) -> JsonObject:
    match parse_json(text):
        case dict() as fields if fields.keys() <= RESULT_FIELDS:
            return fields
        case dict() as fields:
            raise ValueError(
                f"unknown field(s) {sorted(fields.keys() - RESULT_FIELDS)}"
            )
        case _:
            raise ValueError("the result is not a JSON object")


def parse_reason(fields: JsonObject) -> str:
    match fields.get("reason"):
        case str(reason) if reason.strip():
            return reason
        case _:
            raise ValueError("a deny needs a reason")


def emit_result(result: Result) -> str:
    match result:
        case Allow(context=context, updated_input=updated):
            fields: JsonObject = {"decision": "allow"}
            if updated is not None:
                fields["updatedInput"] = updated
        case Deny(reason=reason, context=context):
            fields = {"decision": "deny", "reason": reason}
    if context is not None:
        fields["context"] = context
    return json.dumps(fields)


def optional_str(fields: JsonObject, key: str) -> str | None:
    match fields.get(key):
        case None | "":
            return None
        case str(value):
            return value
        case _:
            raise ValueError(f"{key} is not a string")


def as_list(value: Json) -> list[Json]:
    match value:
        case list():
            return value
        case _:
            raise ValueError(f"not a list: {value!r}")


def as_str(value: Json) -> str:
    match value:
        case str():
            return value
        case _:
            raise ValueError(f"not a string: {value!r}")


def parse_json(text: str) -> Json:
    return cast("Json", json.loads(text))
