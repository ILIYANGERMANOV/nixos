"""agent-hook-opencode: OpenCode's side of the neutral hook contract.

    agent-hook-opencode <tools.json> <manifest.json>

The harness plugin (plugin/kategory.js) runs it at each OpenCode hook with one
envelope on stdin. It turns the envelope into neutral events, runs their hooks
through the frontend's dispatcher (agent_hook.py), and prints what the plugin
does with the result. `tools.json` is codegen/tools.nix, OpenCode's tools by
their vendor-free name; the manifest is the hooks, each event's in order.

The envelope, one JSON object. Ids are OpenCode's session ids:

    hook       before | after | message | command | stop
    sessionID  the session that called
    rootID     its root session, the lead's: sessionID itself for the lead
    agent      the calling session's agent name, null when not yet known
    directory  OpenCode's instance directory
    before:    tool, args              tool.execute.before's
               history                 the session's earlier bash commands, oldest first
    after:     tool, args              tool.execute.after's
               output                  its {title, output, metadata}
               context                 {tokens, previous} | null, the session's
                                       last two model calls' context
               running                 the background children still running
    message:   start                   startup | resume | compact | null: the
                                       session's first chat.message, and why
               parts                   chat.message's parts
               agents                  {sessionID: agent name}, every session seen
               running
    command:   command                 command.execute.before's
    stop:      running                 the root session went idle

It prints, for the plugin:

    before:    {deny: str}             the tool fails with that message
             | {args?, context?}       args: the rewritten args, to set in place;
                                       context: for the tool's output
    others:    {context?}

OpenCode has no hand-back tool: a subagent's last reply is its hand-back. A
task's `<task state="completed">` result, which the parent sees as the tool's
output or, from a background task, as a synthetic part of a chat.message,
becomes the child's `handback` call and its `agentStop`, as Claude Code sends
them. The session is the root's, so a child's bindings sit beside its lead's;
the child is the agent, named by its own session id.

Input it cannot read exits 1 with the error on stderr: the plugin lets the call
go on. A hook's own failure is the dispatcher's, and becomes context.
"""

import json
import re
import sys
from collections.abc import Iterator, Mapping
from dataclasses import dataclass, replace
from functools import reduce
from pathlib import Path

from agent_hook import (
    AfterTool,
    Agent,
    AgentId,
    AgentStart,
    AgentStop,
    Allow,
    BeforeTool,
    Deny,
    Event,
    Json,
    JsonObject,
    Manifest,
    Note,
    PromptExpansion,
    Role,
    SessionId,
    SessionStart,
    SkillName,
    Source,
    Tool,
    Verdict,
    as_list,
    as_str,
    combine_notes,
    dispatch_note,
    dispatch_verdict,
    hooks_for,
    parse_context_size,
    parse_json,
    parse_manifest,
    run_note_hook,
    run_verdict_hook,
)

# OpenCode's tool id -> its vendor-free name.
type ToolNames = Mapping[str, Tool]

# What an envelope asks: a tool call to judge, or events the hooks only
# observe. A synthesized hand-back is among the latter: its child has stopped,
# so its verdict comes too late to deny anything.
type Asked = BeforeTool | tuple[Event, ...]

# OpenCode's argument names -> the neutral input's, which are Claude Code's:
# the kernel and the guards read `file_path`, `skill`, `run_in_background`.
# Keyed by vendor-free tool, as OpenCode has one tool per renamed name.
NEUTRAL_KEYS: Mapping[Tool, Mapping[str, str]] = {
    Tool.READ: {"filePath": "file_path"},
    Tool.EDIT: {
        "filePath": "file_path",
        "oldString": "old_string",
        "newString": "new_string",
        "replaceAll": "replace_all",
    },
    Tool.WRITE: {"filePath": "file_path"},
    Tool.SKILL: {"name": "skill"},
    Tool.DELEGATE: {"background": "run_in_background"},
}

# The task tool's output (OpenCode 1.19.5, tool/task.ts renderOutput). The
# result text may hold anything, a closing tag too: it runs to the block's end.
TASK = re.compile(
    r"""
    <task\ id="([^"]+)"\ state="(running|completed|error)">\n
    (?:<summary>.*?</summary>\n)?
    <(?:task_result|task_error)>\n(.*)\n</(?:task_result|task_error)>\n
    </task>
    """,
    re.DOTALL | re.VERBOSE,
)


def main() -> None:
    try:
        tools_path, manifest_path = sys.argv[1:]
        tools = parse_tools(Path(tools_path).read_text())
        manifest = parse_manifest(Path(manifest_path).read_text())
        asked = parse_opencode(parse_json(sys.stdin.read()), tools)
    except ValueError as error:
        sys.exit(f"agent-hook-opencode: {error}")
    print(json.dumps(answer(manifest, asked)))


def answer(manifest: Manifest, asked: Asked) -> JsonObject:
    match asked:
        case BeforeTool() as event:
            verdict = dispatch_verdict(
                hooks_for(manifest, event), event, run_verdict_hook
            )
            return verdict_to_opencode(verdict, event.tool)
        case tuple() as events:
            return note_to_opencode(
                reduce(
                    combine_notes,
                    (observe(manifest, event) for event in events),
                    Note(),
                )
            )


def observe(manifest: Manifest, event: Event) -> Note:
    """What the parent is told of an event it only observes. Nothing of a
    stop, as Claude's adapter, nor of a synthesized hand-back, whose context
    is for a child that has already stopped."""
    hooks = hooks_for(manifest, event)
    match event:
        case BeforeTool():
            _ = dispatch_verdict(hooks, event, run_verdict_hook)
            return Note()
        case AgentStop():
            _ = dispatch_note(hooks, event, run_note_hook)
            return Note()
        case SessionStart() | AfterTool() | AgentStart() | PromptExpansion():
            return dispatch_note(hooks, event, run_note_hook)


def parse_tools(text: str) -> ToolNames:
    """Inverts the table: each OpenCode tool belongs to one vendor-free name. A
    name OpenCode has no tool for is null."""
    match parse_json(text):
        case dict() as table:
            return {
                as_str(tool): Tool(name)
                for name, entry in table.items()
                for tool in table_tools(entry)
            }
        case _:
            raise ValueError("the tool table is not a JSON object")


def table_tools(entry: Json) -> list[Json]:
    match entry:
        case None:
            return []
        case {"tools": tools}:
            return as_list(tools)
        case _:
            raise ValueError(f"not a tool table entry: {entry!r}")


def parse_opencode(payload: Json, tools: ToolNames) -> Asked:
    match payload:
        case {"directory": str(directory)}:
            session, agent = parse_caller(payload)
            cwd = Path(directory)
        case _:
            raise ValueError("the envelope is no object with a directory")
    match payload:
        case {
            "hook": "before",
            "tool": str(name),
            "args": dict() as args,
            "history": list() as history,
        }:
            tool = vendor_free(tools, name)
            return BeforeTool(
                session,
                tool_cwd(cwd, tool, args),
                agent,
                tool,
                neutral_input(tool, args),
                tuple(as_str(command) for command in history)
                if tool == Tool.SHELL
                else (),
            )
        case {
            "hook": "after",
            "tool": str(name),
            "args": dict() as args,
            "output": dict() as output,
            "context": context,
            "running": list() as running,
        }:
            tool = vendor_free(tools, name)
            ran = AfterTool(
                session,
                tool_cwd(cwd, tool, args),
                agent,
                tool,
                neutral_input(tool, args),
                output,
                parse_context_size(context),
            )
            return tool_ran(ran, output.get("output"), running_ids(running))
        case {
            "hook": "message",
            "start": start,
            "parts": list() as parts,
            "agents": dict() as agents,
            "running": list() as running,
        }:
            still = running_ids(running)
            return started(session, cwd, agent, start) + tuple(
                event
                for result in background_results(parts)
                for event in task_ended(
                    session, cwd, result, optional_role(agents.get(result.child)), still
                )
            )
        case {"hook": "command", "command": str(command)}:
            return (PromptExpansion(session, cwd, agent, SkillName(command)),)
        case {"hook": "stop", "running": list() as running}:
            return (AgentStop(session, cwd, agent, running_ids(running)),)
        case _:
            raise ValueError(
                "not a before, after, message, command or stop envelope with its fields"
            )


def tool_ran(
    ran: AfterTool, output: Json, running: tuple[AgentId, ...]
) -> tuple[Event, ...]:
    """The output as the kernel reads it: a shell's `stdout`, a spawn's
    `agentId`, after the events of the spawned child's end. Any other tool's
    is OpenCode's own."""
    match ran.tool:
        case Tool.SHELL:
            return (replace(ran, output={"stdout": as_str(output)}),)
        case Tool.DELEGATE:
            result = parse_task(as_str(output))
            ended = task_ended(
                ran.session,
                ran.cwd,
                result,
                optional_role(ran.input.get("subagent_type")),
                running,
            )
            return (*ended, replace(ran, output={"agentId": result.child}))
        case _:
            return (ran,)


def parse_caller(payload: JsonObject) -> tuple[SessionId, Agent | None]:
    """The neutral session is the root's; the lead is no agent, and a child is
    the agent its own session id names, of the role its agent name gives."""
    match payload:
        case {"sessionID": str(own), "rootID": str(root)} if own == root:
            return SessionId(root), None
        case {"sessionID": str(own), "rootID": str(root), "agent": str(role)}:
            return SessionId(root), Agent(AgentId(own), Role(role))
        case {"sessionID": str(own), "rootID": str(root), "agent": None}:
            return SessionId(root), Agent(AgentId(own), None)
        case _:
            raise ValueError("the envelope names no sessionID, rootID and agent")


def vendor_free(tools: ToolNames, name: str) -> Tool:
    return tools.get(name, Tool.OTHER)


def tool_cwd(cwd: Path, tool: Tool, args: JsonObject) -> Path:
    """Where the call runs: a bash call's `workdir`, relative to the instance
    directory, else that directory. The kernel tells a run by it."""
    match tool, args.get("workdir"):
        case Tool.SHELL, str(workdir):
            return cwd / workdir
        case _:
            return cwd


def neutral_input(tool: Tool, args: JsonObject) -> JsonObject:
    return renamed(args, NEUTRAL_KEYS.get(tool, {}))


def renamed(fields: JsonObject, names: Mapping[str, str]) -> JsonObject:
    return {names.get(key, key): value for key, value in fields.items()}


def running_ids(running: list[Json]) -> tuple[AgentId, ...]:
    return tuple(AgentId(as_str(child)) for child in running)


def optional_role(agent: Json) -> Role | None:
    """An agent name, if OpenCode has told it."""
    match agent:
        case str(role):
            return Role(role)
        case _:
            return None


def started(
    session: SessionId, cwd: Path, agent: Agent | None, start: Json
) -> tuple[Event, ...]:
    """A session's first message starts it: the lead's session, or a child."""
    match start, agent:
        case None, _:
            return ()
        case str(source), None:
            return (SessionStart(session, cwd, None, Source(source)),)
        case str(), Agent():
            return (AgentStart(session, cwd, agent),)
        case _:
            raise ValueError(f"start {start!r} is not a string")


# ---- A task's result ---------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class Running:
    """A background task started, or resumed."""

    child: AgentId


@dataclass(frozen=True, slots=True)
class Completed:
    child: AgentId
    text: str


@dataclass(frozen=True, slots=True)
class Failed:
    child: AgentId


type TaskResult = Running | Completed | Failed


def parse_task(output: str) -> TaskResult:
    match task_result(output):
        case None:
            raise ValueError("a task's output is no <task> block")
        case result:
            return result


def background_results(parts: list[Json]) -> Iterator[TaskResult]:
    """The task results among a message's parts: OpenCode prompts a parent
    with a synthetic text part when its background task ends."""
    for part in parts:
        match part:
            case {"type": "text", "synthetic": True, "text": str(text)}:
                match task_result(text):
                    case None:
                        pass
                    case result:
                        yield result
            case _:
                pass


def task_result(text: str) -> TaskResult | None:
    match TASK.fullmatch(text):
        case None:
            return None
        case found:
            child, state, result = found.groups()
            match state:
                case "running":
                    return Running(AgentId(child))
                case "completed":
                    return Completed(AgentId(child), result)
                case _:
                    return Failed(AgentId(child))


def task_ended(
    session: SessionId,
    cwd: Path,
    result: TaskResult,
    role: Role | None,
    running: tuple[AgentId, ...],
) -> tuple[Event, ...]:
    """A finished child's hand-back, its last reply, and its stop. The child
    is running no more, whatever the plugin last saw."""
    still = tuple(child for child in running if child != result.child)
    match result:
        case Running():
            return ()
        case Completed(child=child, text=text):
            agent = Agent(child, role)
            return (
                BeforeTool(session, cwd, agent, Tool.HANDBACK, {"message": text}),
                AgentStop(session, cwd, agent, still),
            )
        case Failed(child=child):
            return (AgentStop(session, cwd, Agent(child, role), still),)


# ---- The plugin's output ------------------------------------------------------------


def verdict_to_opencode(verdict: Verdict, tool: Tool) -> JsonObject:
    """A deny's message is all the model sees of the call, so it carries the
    context too. A rewrite comes back in OpenCode's argument names."""
    match verdict:
        case Deny(reason=reason, context=context):
            return {"deny": reason if context is None else f"{reason}\n\n{context}"}
        case Allow(context=context, updated_input=updated):
            back = {neutral: key for key, neutral in NEUTRAL_KEYS.get(tool, {}).items()}
            rewrite: JsonObject = (
                {} if updated is None else {"args": renamed(updated, back)}
            )
            return rewrite | note_to_opencode(Note(context))


def note_to_opencode(note: Note) -> JsonObject:
    match note.context:
        case None:
            return {}
        case context:
            return {"context": context}


if __name__ == "__main__":
    main()
