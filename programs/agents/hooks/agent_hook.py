"""The neutral hook contract, the same for every agent, and the dispatcher.

A hook is a program. It reads one event as JSON on stdin and prints one result
as JSON on stdout, or nothing, which allows:

    stdin:  {event, session, cwd, agent: {id, role} | null, harness, transcript_path,
             tool, call, input, output, source, request_model, history, context,
             skill, running, usage}
    stdout: beforeTool: {decision: allow | deny, reason, context, updatedInput}
            sessionStart, afterTool, agentStart, promptExpansion: {context}
            agentStop: dropped

`agent` is null for the lead; a subagent's `id` is null when its agent gives
none, and its `role` null when its agent names none. `tool` is `other` for a tool the vocabulary has no name for, which
only a hook declared with no tools sees. A backend fills two facts from what
the agent has done so far, so a hook needs no state of its own:

    history: beforeTool: the agent's recent shell commands, oldest first,
             the call under judgement not among them; [] for any other tool
             or when the backend cannot tell
    context: afterTool: {tokens, previous} | null, the tokens of context the
             newest model call sent, and those of the last earlier call that
             ran a tool (null when there is none); null when unknown

Every event names the harness that runs the session (`harness`, its
backend's own constant: `claude-code`, `opencode`) and, as `null` when its
harness gives none, the session's transcript file (`transcript_path`, an
absolute path). A sessionStart also names the model it asked for
(`request_model`, `null` when none).

A beforeTool or afterTool names its tool call (`call`, the harness's own id of
it, OpenTelemetry's `gen_ai.tool.call.id`), `null` when the harness gives none:
a spawn's afterTool shares its beforeTool's. A hand-back's beforeTool and an
agentStop carry the tokens the agent's own requests used, its subagents' aside
(`usage`), `null` when unknown and on every other beforeTool:

    usage: {input_tokens?, output_tokens?, cache_read_input_tokens?,
            cache_write_input_tokens?} | null

`input_tokens` counts the cached ones too. A count the harness does not report
is left out, never 0.

`agentStart` is a subagent starting, its `agent` never null; `promptExpansion`
is a typed `/skill` expanding into the prompt, `skill` its name. `agentStop`
is an agent stopping, handed back or not, the lead too (`agent` null);
`running` is the ids of the session's background agents still running, which
at a subagent's own stop may still list it. None of the three has a tool, so
none has `tool`, `input` or `output`.

A sessionStart, afterTool, agentStart or promptExpansion hook only adds
context: the session or subagent has started and the tool has run, so there
is nothing left to deny or rewrite, and a typed skill is the person's own
request, which no hook refuses. Each kind of event has its own result type,
so a deny there cannot even be built. An agentStop hook runs for its effect
alone: the agent has stopped, so the backend hands no context on and what the
hook prints is dropped.

An agent's backend translates its own hook format to an `Event`, hands it to
`dispatch_verdict` or `dispatch_note` with the hooks declared for that event,
and translates the result back. So every backend runs the same hooks in the
same order with the same outcome, whatever its own hooks do with order or
parallelism.

The names an event, tool or source can take are `vocabulary.json`'s, which the
Nix declarations read too; a test holds the enums below to it.
"""

import json
import subprocess
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field, replace
from enum import StrEnum
from functools import reduce
from pathlib import Path
from typing import NewType, cast

# What `json.loads` can return, spelled out because typeshed says Any.
type Json = None | bool | int | float | str | list[Json] | dict[str, Json]
type JsonObject = dict[str, Json]

SessionId = NewType("SessionId", str)
AgentId = NewType("AgentId", str)
Role = NewType("Role", str)
HookName = NewType("HookName", str)
CallId = NewType("CallId", str)
Harness = NewType("Harness", str)
SkillName = NewType("SkillName", str)


class EventName(StrEnum):
    SESSION_START = "sessionStart"
    BEFORE_TOOL = "beforeTool"
    AFTER_TOOL = "afterTool"
    AGENT_START = "agentStart"
    PROMPT_EXPANSION = "promptExpansion"
    AGENT_STOP = "agentStop"


class Tool(StrEnum):
    SHELL = "shell"
    READ = "read"
    EDIT = "edit"
    WRITE = "write"
    DELEGATE = "delegate"
    HANDBACK = "handback"
    WEB = "web"
    SKILL = "skill"
    STOP_AGENT = "stopAgent"
    OTHER = "other"


class Source(StrEnum):
    """Why a session started: a new one, a resumed one, or one just compacted."""

    STARTUP = "startup"
    RESUME = "resume"
    COMPACT = "compact"


@dataclass(frozen=True, slots=True)
class Agent:
    """The subagent making the call; the lead is no agent. `id` is None when its
    agent gives none, so such subagents cannot be told apart. `role` is its
    type, None when its agent names none."""

    id: AgentId | None
    role: Role | None


@dataclass(frozen=True, slots=True)
class ContextSize:
    """Tokens of context: what the newest model call sent, and what the last
    earlier call that ran a tool sent, None when there is no such call."""

    tokens: int
    previous: int | None


@dataclass(frozen=True, slots=True)
class Usage:
    """The tokens an agent's own requests used; a count not reported is None,
    never 0. `input` includes the cached tokens."""

    input: int | None = None
    output: int | None = None
    cache_read: int | None = None
    cache_write: int | None = None


@dataclass(frozen=True, slots=True)
class SessionStart:
    """A session starts. `transcript` is absolute; it and `model` are None when
    the harness gives none. Every other event names `harness` and `transcript`
    too."""

    session: SessionId
    cwd: Path
    agent: Agent | None
    source: Source
    harness: Harness
    transcript: Path | None
    model: str | None


@dataclass(frozen=True, slots=True)
class BeforeTool:
    """A tool is about to run. `call` is the harness's id of the call, None
    when it gives none; `usage` is a hand-back's, None for every other tool."""

    session: SessionId
    cwd: Path
    agent: Agent | None
    tool: Tool
    input: JsonObject
    history: tuple[str, ...] = ()
    harness: Harness = field(kw_only=True)
    transcript: Path | None = field(default=None, kw_only=True)
    call: CallId | None = field(default=None, kw_only=True)
    usage: Usage | None = field(default=None, kw_only=True)


@dataclass(frozen=True, slots=True)
class AfterTool:
    """A tool ran. `call` is the harness's id of the call, None when it gives
    none."""

    session: SessionId
    cwd: Path
    agent: Agent | None
    tool: Tool
    input: JsonObject
    output: Json
    context: ContextSize | None = None
    harness: Harness = field(kw_only=True)
    transcript: Path | None = field(default=None, kw_only=True)
    call: CallId | None = field(default=None, kw_only=True)


@dataclass(frozen=True, slots=True)
class AgentStart:
    """A subagent starts, before its first model call."""

    session: SessionId
    cwd: Path
    agent: Agent
    harness: Harness = field(kw_only=True)
    transcript: Path | None = field(default=None, kw_only=True)


@dataclass(frozen=True, slots=True)
class PromptExpansion:
    """A skill the person typed as `/<skill>` expands into the prompt."""

    session: SessionId
    cwd: Path
    agent: Agent | None
    skill: SkillName
    harness: Harness = field(kw_only=True)
    transcript: Path | None = field(default=None, kw_only=True)


@dataclass(frozen=True, slots=True)
class AgentStop:
    """An agent stops, the lead when `agent` is None. `running` is the
    session's background agents still running, maybe the stopping one;
    `usage` the tokens its own requests used, None when unknown."""

    session: SessionId
    cwd: Path
    agent: Agent | None
    running: tuple[AgentId, ...]
    harness: Harness = field(kw_only=True)
    transcript: Path | None = field(default=None, kw_only=True)
    usage: Usage | None = field(default=None, kw_only=True)


type Event = (
    SessionStart | BeforeTool | AfterTool | AgentStart | PromptExpansion | AgentStop
)

# The events a hook cannot deny: it adds context, or at agentStop nothing.
type Observed = SessionStart | AfterTool | AgentStart | PromptExpansion | AgentStop


@dataclass(frozen=True, slots=True)
class Allow:
    """The call goes on, with its input rewritten when `updated_input` is set."""

    context: str | None = None
    updated_input: JsonObject | None = None


@dataclass(frozen=True, slots=True)
class Deny:
    """The call does not happen."""

    reason: str
    context: str | None = None


# A beforeTool hook's result.
type Verdict = Allow | Deny


@dataclass(frozen=True, slots=True)
class Note:
    """A hook's result at an event it only observes: context for the agent."""

    context: str | None = None


# What a hook prints, whatever its event.
type Result = Verdict | Note


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

RESULT_FIELDS = frozenset({"decision", "reason", "context", "updatedInput"})
NOTE_FIELDS = frozenset({"context"})


def dispatch_verdict(
    hooks: Sequence[Hook],
    event: BeforeTool,
    run: Callable[[Hook, BeforeTool], Verdict],
) -> Verdict:
    """Runs the hooks that match `event` in order and folds their verdicts.

    Each hook sees the input the hooks before it rewrote. A deny does not stop
    the chain: every hook runs, so the agent learns every reason at once
    rather than one per retry.
    """
    verdict: Verdict = Allow()
    seen = event
    for hook in hooks:
        if not matches(hook, event):
            continue
        result = run(hook, seen)
        verdict = combine_verdicts(verdict, result)
        seen = threaded(seen, result)
    return verdict


def dispatch_note(
    hooks: Sequence[Hook], event: Observed, run: Callable[[Hook, Observed], Note]
) -> Note:
    """Runs the hooks that match `event` in order and joins their notes."""
    notes = (run(hook, event) for hook in hooks if matches(hook, event))
    return reduce(combine_notes, notes, Note())


def combine_verdicts(first: Verdict, second: Verdict) -> Verdict:
    """The verdicts' monoid, `Allow()` its identity: deny wins, contexts and
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


def combine_notes(first: Note, second: Note) -> Note:
    """The notes' monoid, `Note()` its identity: contexts join in order."""
    return Note(joined(first.context, second.context))


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
        case SessionStart() | AgentStart() | PromptExpansion() | AgentStop():
            return True
        case BeforeTool(tool=tool) | AfterTool(tool=tool):
            match hook.tools:
                case EveryTool():
                    return True
                case frozenset() as tools:
                    return tool in tools


def threaded(event: BeforeTool, verdict: Verdict) -> BeforeTool:
    """The event the next hook sees: `event`'s input, as `verdict` rewrote it."""
    match verdict:
        case Allow(updated_input=dict() as updated):
            return replace(event, input=updated)
        case Allow() | Deny():
            return event


def run_verdict_hook(hook: Hook, event: BeforeTool) -> Verdict:
    return run_hook(hook, event, parse_verdict, lambda context: Allow(context=context))


def run_note_hook(hook: Hook, event: Observed) -> Note:
    return run_hook(hook, event, parse_note, Note)


def run_hook[R](
    hook: Hook, event: Event, parse: Callable[[str], R], tell: Callable[[str], R]
) -> R:
    """Runs one hook. One that fails, or prints what the contract does not
    allow, never blocks the call: `tell` turns its error into context, so the
    agent learns of it."""
    try:
        done = subprocess.run(
            hook.command,
            input=emit_event(event),
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as error:
        return tell(told(hook, str(error)))
    if done.returncode != 0:
        lines = done.stderr.strip().splitlines()
        return tell(told(hook, f"exit {done.returncode}: {lines[-1] if lines else ''}"))
    try:
        return parse(done.stdout)
    except ValueError as error:
        return tell(told(hook, f"bad output: {error}"))


def told(hook: Hook, error: str) -> str:
    return f"hook {hook.name}: {error}"


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
        case AgentStart():
            return EventName.AGENT_START
        case PromptExpansion():
            return EventName.PROMPT_EXPANSION
        case AgentStop():
            return EventName.AGENT_STOP


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
            "harness": str(harness),
            "transcript_path": transcript,
            "source": str(source),
            "request_model": None | str() as model,
        }:
            return SessionStart(
                SessionId(session),
                Path(cwd),
                parse_agent(agent),
                Source(source),
                Harness(harness),
                parse_transcript(transcript),
                model,
            )
        case {
            "event": "beforeTool",
            "session": str(session),
            "cwd": str(cwd),
            "agent": agent,
            "harness": str(harness),
            "transcript_path": transcript,
            "tool": str(tool),
            "call": None | str() as call,
            "input": dict() as tool_input,
            "history": list() as history,
            "usage": usage,
        }:
            return BeforeTool(
                SessionId(session),
                Path(cwd),
                parse_agent(agent),
                Tool(tool),
                tool_input,
                tuple(as_str(command) for command in history),
                harness=Harness(harness),
                transcript=parse_transcript(transcript),
                call=None if call is None else CallId(call),
                usage=parse_usage(usage),
            )
        case {
            "event": "afterTool",
            "session": str(session),
            "cwd": str(cwd),
            "agent": agent,
            "harness": str(harness),
            "transcript_path": transcript,
            "tool": str(tool),
            "call": None | str() as call,
            "input": dict() as tool_input,
            "output": output,
            "context": context,
        }:
            return AfterTool(
                SessionId(session),
                Path(cwd),
                parse_agent(agent),
                Tool(tool),
                tool_input,
                output,
                parse_context_size(context),
                harness=Harness(harness),
                transcript=parse_transcript(transcript),
                call=None if call is None else CallId(call),
            )
        case {
            "event": "agentStart",
            "session": str(session),
            "cwd": str(cwd),
            "agent": agent,
            "harness": str(harness),
            "transcript_path": transcript,
        }:
            return AgentStart(
                SessionId(session),
                Path(cwd),
                parse_subagent(agent),
                harness=Harness(harness),
                transcript=parse_transcript(transcript),
            )
        case {
            "event": "promptExpansion",
            "session": str(session),
            "cwd": str(cwd),
            "agent": agent,
            "harness": str(harness),
            "transcript_path": transcript,
            "skill": str(skill),
        }:
            return PromptExpansion(
                SessionId(session),
                Path(cwd),
                parse_agent(agent),
                SkillName(skill),
                harness=Harness(harness),
                transcript=parse_transcript(transcript),
            )
        case {
            "event": "agentStop",
            "session": str(session),
            "cwd": str(cwd),
            "agent": agent,
            "harness": str(harness),
            "transcript_path": transcript,
            "running": list() as running,
            "usage": usage,
        }:
            return AgentStop(
                SessionId(session),
                Path(cwd),
                parse_agent(agent),
                tuple(AgentId(as_str(agent_id)) for agent_id in running),
                harness=Harness(harness),
                transcript=parse_transcript(transcript),
                usage=parse_usage(usage),
            )
        case _:
            raise ValueError(
                "not a sessionStart, beforeTool, afterTool, agentStart, promptExpansion or agentStop event"
            )


def parse_agent(agent: Json) -> Agent | None:
    match agent:
        case None:
            return None
        case _:
            return parse_subagent(agent)


def parse_subagent(agent: Json) -> Agent:
    match agent:
        case {"id": None | str() as agent_id, "role": None | str() as role}:
            return Agent(
                None if agent_id is None else AgentId(agent_id),
                None if role is None else Role(role),
            )
        case _:
            raise ValueError(f"not an agent: {agent!r}")


def parse_transcript(transcript: Json) -> Path | None:
    """A session's transcript file: an absolute, normalised path, or None when
    there is none. The kernel refuses any other, so it is refused here."""
    match transcript:
        case None:
            return None
        case str() if absolute_normalised(transcript):
            return Path(transcript)
        case _:
            raise ValueError(
                f"not an absolute normalised transcript path: {transcript!r}"
            )


def absolute_normalised(path: str) -> bool:
    """What the kernel's `absPath` takes: an absolute path equal to Haskell
    filepath's `normalise` of it. That collapses `//` and drops a `.` part,
    but keeps a `..` part and a trailing `/`."""
    match path.split("/"):
        case ["", *inner, last]:
            return all(part not in ("", ".") for part in inner) and last != "."
        case _:
            return False


USAGE_KEYS = (
    "input_tokens",
    "output_tokens",
    "cache_read_input_tokens",
    "cache_write_input_tokens",
)


def parse_usage(usage: Json) -> Usage | None:
    """The tokens an agent used: each count a non-negative integer, or left out."""
    match usage:
        case None:
            return None
        case dict() if set(usage) <= set(USAGE_KEYS):
            return Usage(*(parse_count(usage.get(key)) for key in USAGE_KEYS))
        case _:
            raise ValueError(f"not a usage: {usage!r}")


def parse_count(count: Json) -> int | None:
    match count:
        case None:
            return None
        case int() if not isinstance(count, bool) and count >= 0:
            return count
        case _:
            raise ValueError(f"not a token count: {count!r}")


def parse_context_size(context: Json) -> ContextSize | None:
    match context:
        case None:
            return None
        case {"tokens": int(tokens), "previous": None | int() as previous}:
            return ContextSize(tokens, previous)
        case _:
            raise ValueError(f"not a context size: {context!r}")


def emit_event(event: Event) -> str:
    common: JsonObject = {
        "event": event_name(event).value,
        "session": event.session,
        "cwd": str(event.cwd),
        "agent": emit_agent(event.agent),
        "harness": event.harness,
        "transcript_path": None if event.transcript is None else str(event.transcript),
    }
    match event:
        case AgentStart():
            return json.dumps(common)
        case PromptExpansion(skill=skill):
            return json.dumps(common | {"skill": skill})
        case AgentStop(running=running, usage=usage):
            return json.dumps(
                common | {"running": list(running), "usage": emit_usage(usage)}
            )
        case SessionStart(source=source, model=model):
            return json.dumps(common | {"source": source.value, "request_model": model})
        case BeforeTool(
            tool=tool, call=call, input=tool_input, history=history, usage=usage
        ):
            return json.dumps(
                common
                | {
                    "tool": tool.value,
                    "call": call,
                    "input": tool_input,
                    "history": list(history),
                    "usage": emit_usage(usage),
                }
            )
        case AfterTool(
            tool=tool, call=call, input=tool_input, output=output, context=context
        ):
            return json.dumps(
                common
                | {
                    "tool": tool.value,
                    "call": call,
                    "input": tool_input,
                    "output": output,
                    "context": emit_context_size(context),
                }
            )


def emit_agent(agent: Agent | None) -> Json:
    match agent:
        case None:
            return None
        case Agent(id=agent_id, role=role):
            return {"id": agent_id, "role": role}


def emit_usage(usage: Usage | None) -> Json:
    match usage:
        case None:
            return None
        case Usage():
            counts = (usage.input, usage.output, usage.cache_read, usage.cache_write)
            return {
                key: count
                for key, count in zip(USAGE_KEYS, counts, strict=True)
                if count is not None
            }


def emit_context_size(context: ContextSize | None) -> Json:
    match context:
        case None:
            return None
        case ContextSize(tokens=tokens, previous=previous):
            return {"tokens": tokens, "previous": previous}


def parse_verdict(text: str) -> Verdict:
    """What a beforeTool hook printed. Empty allows."""
    if not text.strip():
        return Allow()
    fields = result_fields(text)
    context = optional_str(fields, "context")
    match fields.get("decision", "allow"):
        case "deny":
            return parse_deny(fields, context)
        case "allow":
            return parse_allow(fields, context)
        case decision:
            raise ValueError(f"unknown decision {decision!r}")


def parse_note(text: str) -> Note:
    """What a hook printed at an event it only observes. A field only a
    verdict has, such as a deny after the tool ran, is an error rather than
    dropped."""
    if not text.strip():
        return Note()
    fields = result_fields(text)
    match sorted(fields.keys() - NOTE_FIELDS):
        case []:
            return Note(optional_str(fields, "context"))
        case verdict_fields:
            raise ValueError(f"only beforeTool may set {verdict_fields}")


def parse_deny(fields: JsonObject, context: str | None) -> Deny:
    match fields.get("updatedInput"):
        case None:
            return Deny(parse_reason(fields), context)
        case _:
            raise ValueError("a deny rewrites no input")


def parse_allow(fields: JsonObject, context: str | None) -> Allow:
    if "reason" in fields:
        raise ValueError("only a deny has a reason")
    match fields.get("updatedInput"):
        case None:
            return Allow(context)
        case dict() as updated:
            return Allow(context, updated)
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
        case Note(context=context):
            fields = {}
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
