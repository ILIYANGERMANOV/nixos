"""agent-hook-claude: Claude Code's side of the neutral hook contract.

    agent-hook-claude <tools.json> <manifest.json>

Claude runs it for every event a profile's hooks use. It turns Claude's hook
JSON into a neutral event, runs that event's hooks through the frontend's
dispatcher (agent_hook.py), and prints the folded result as Claude's output.
`tools.json` is codegen/tools.nix, Claude's tools by their vendor-free name;
the manifest is the hooks, each event's in order. A tool with no vendor-free
name is `other`, which only hooks naming no tools see.

A shell call's `history` and a tool result's `context` come from the calling
agent's own transcript, its last TAIL_BYTES only. A transcript it cannot read
gives none: they are facts a hook may use, never a reason to fail the call.

Input it cannot read exits 1 with the error on stderr: Claude shows it and lets
the call go on. A hook's own failure is the dispatcher's, and becomes context.
"""

import json
import os
import sys
from collections.abc import Callable, Iterator, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path

from agent_hook import (
    AfterTool,
    Agent,
    AgentId,
    Allow,
    BeforeTool,
    ContextSize,
    Deny,
    Event,
    Json,
    JsonObject,
    Manifest,
    Note,
    Observed,
    Role,
    SessionId,
    SessionStart,
    Source,
    Tool,
    Verdict,
    as_list,
    as_str,
    dispatch_note,
    dispatch_verdict,
    hooks_for,
    parse_json,
    parse_manifest,
    run_note_hook,
    run_verdict_hook,
)

# Claude's tool name -> its vendor-free name.
type ToolNames = Mapping[str, Tool]

# A transcript's lines, read on demand: most events need none.
type ReadLines = Callable[[Path], Sequence[bytes]]

# Enough for two model calls unless a single result is larger, which only
# costs `previous`; and for the shell commands a subagent ran lately.
TAIL_BYTES = 256 * 1024


def main() -> None:
    try:
        tools_path, manifest_path = sys.argv[1:]
        tools = parse_tools(Path(tools_path).read_text())
        manifest = parse_manifest(Path(manifest_path).read_text())
        event = parse_claude(parse_json(sys.stdin.read()), tools, tail_lines)
    except ValueError as error:
        sys.exit(f"agent-hook-claude: {error}")
    print(json.dumps(answer(manifest, event)))


def answer(manifest: Manifest, event: Event) -> JsonObject:
    hooks = hooks_for(manifest, event)
    match event:
        case BeforeTool():
            return verdict_to_claude(dispatch_verdict(hooks, event, run_verdict_hook))
        case SessionStart() | AfterTool():
            return note_to_claude(event, dispatch_note(hooks, event, run_note_hook))


def parse_tools(text: str) -> ToolNames:
    """Inverts the table: each Claude tool belongs to one vendor-free name."""
    match parse_json(text):
        case dict() as table:
            return {
                as_str(claude): Tool(name)
                for name, claudes in table.items()
                for claude in as_list(claudes)
            }
        case _:
            raise ValueError("the tool table is not a JSON object")


def parse_claude(payload: Json, tools: ToolNames, read: ReadLines) -> Event:
    match payload:
        case {
            "hook_event_name": "SessionStart",
            "session_id": str(session),
            "cwd": str(cwd),
            "source": str(source),
        }:
            return SessionStart(
                SessionId(session), Path(cwd), parse_agent(payload), Source(source)
            )
        case {
            "hook_event_name": "PreToolUse",
            "session_id": str(session),
            "cwd": str(cwd),
            "tool_name": str(name),
            "tool_input": dict() as tool_input,
        }:
            agent = parse_agent(payload)
            tool = vendor_free(tools, name)
            return BeforeTool(
                SessionId(session),
                Path(cwd),
                agent,
                tool,
                tool_input,
                shell_history(
                    transcript(payload.get("transcript_path"), agent, read),
                    tools,
                    skip=payload.get("tool_use_id"),
                )
                if tool == Tool.SHELL
                else (),
            )
        case {
            "hook_event_name": "PostToolUse",
            "session_id": str(session),
            "cwd": str(cwd),
            "tool_name": str(name),
            "tool_input": dict() as tool_input,
            "tool_response": output,
        }:
            agent = parse_agent(payload)
            return AfterTool(
                SessionId(session),
                Path(cwd),
                agent,
                vendor_free(tools, name),
                tool_input,
                output,
                context_size(transcript(payload.get("transcript_path"), agent, read)),
            )
        case _:
            raise ValueError("not a SessionStart, PreToolUse or PostToolUse event")


def parse_agent(payload: JsonObject) -> Agent | None:
    """Claude names a subagent by `agent_id` and its type; the lead has neither.
    A lead started with --agent has a type but no id: it is still the lead. A
    subagent whose type is null or missing is one with no role."""
    match payload:
        case {"agent_id": str(agent_id)}:
            match payload.get("agent_type"):
                case str(role):
                    return Agent(AgentId(agent_id), Role(role))
                case None:
                    return Agent(AgentId(agent_id), None)
                case role:
                    raise ValueError(f"agent_type {role!r} is not a string")
        case {"agent_id": agent_id}:
            raise ValueError(f"agent_id {agent_id!r} is not a string")
        case _:
            return None


def vendor_free(tools: ToolNames, name: str) -> Tool:
    return tools.get(name, Tool.OTHER)


# ---- The transcript ----------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class ToolUse:
    id: str
    name: str
    input: JsonObject


@dataclass(frozen=True, slots=True)
class ModelLine:
    """One content block of a model call: the transcript writes each block as
    its own line, every one with the call's usage. `tokens` is 0 with none."""

    message_id: str | None
    tokens: int
    tool_uses: list[ToolUse]


def transcript(path: Json, agent: Agent | None, read: ReadLines) -> list[ModelLine]:
    """The model calls in the tail of the transcript of the agent that called.

    `transcript_path` always names the main session's. A subagent's, at any
    depth, sits under the session's own directory, named after its `agent_id`.
    """
    match path, agent:
        case str(main), None:
            own = Path(main)
        case str(main), Agent(id=agent_id):
            own = Path(main).with_suffix("") / "subagents" / f"agent-{agent_id}.jsonl"
        case _:
            return []
    return [line for raw in read(own) if (line := parse_model_line(raw)) is not None]


def tail_lines(path: Path) -> list[bytes]:
    """The file's last TAIL_BYTES as lines, the first maybe partial; none when
    it cannot be read, for the facts it gives are optional."""
    try:
        with path.open("rb") as file:
            _ = file.seek(0, os.SEEK_END)
            _ = file.seek(max(0, file.tell() - TAIL_BYTES))
            return file.read().splitlines()
    except OSError:
        return []


def shell_history(
    lines: list[ModelLine], tools: ToolNames, skip: Json
) -> tuple[str, ...]:
    """The agent's shell commands, oldest first, but for `skip`, the id of the
    call under judgement, which the transcript may already hold."""
    return tuple(
        command
        for line in lines
        for use in line.tool_uses
        if use.id != skip
        for command in shell_command(use, tools)
    )


def shell_command(use: ToolUse, tools: ToolNames) -> Iterator[str]:
    match use:
        case ToolUse(name=name, input={"command": str(command)}) if (
            vendor_free(tools, name) == Tool.SHELL
        ):
            yield command
        case _:
            pass


def context_size(lines: list[ModelLine]) -> ContextSize | None:
    """The newest call's context, and that of the last call before it that ran
    a tool: the last one a tool result followed, so the last a hook saw."""
    sizes: dict[str, int] = {}
    ran_tool: set[str] = set()
    for line in reversed(lines):
        match line:
            case ModelLine(str() as message_id, tokens, uses) if tokens > 0:
                _ = sizes.setdefault(message_id, tokens)
                if uses:
                    ran_tool.add(message_id)
            case _:
                pass
    match list(sizes):
        case [newest, *older]:
            previous = next((sizes[call] for call in older if call in ran_tool), None)
            return ContextSize(sizes[newest], previous)
        case _:
            return None


def parse_model_line(line: bytes) -> ModelLine | None:
    """None for any other line, and for a partial one of a tail or a running write."""
    try:
        parsed = parse_json(line.decode())
    except ValueError:
        return None
    match parsed:
        case {"type": "assistant", "message": dict() as message}:
            message_id = message.get("id")
            return ModelLine(
                message_id if isinstance(message_id, str) else None,
                usage_tokens(message.get("usage")),
                [
                    use
                    for block in as_blocks(message.get("content"))
                    for use in tool_use(block)
                ],
            )
        case _:
            return None


def usage_tokens(usage: Json) -> int:
    """All the context a call sent: fresh input plus what the cache read and wrote."""
    match usage:
        case dict() as counts:
            return sum(
                tokens
                for key in (
                    "input_tokens",
                    "cache_read_input_tokens",
                    "cache_creation_input_tokens",
                )
                if isinstance(tokens := counts.get(key), int)
            )
        case _:
            return 0


def as_blocks(content: Json) -> list[Json]:
    match content:
        case list():
            return content
        case _:
            return []


def tool_use(block: Json) -> Iterator[ToolUse]:
    match block:
        case {
            "type": "tool_use",
            "id": str(use_id),
            "name": str(name),
            "input": dict() as tool_input,
        }:
            yield ToolUse(use_id, name, tool_input)
        case _:
            pass


def verdict_to_claude(verdict: Verdict) -> JsonObject:
    """Claude's PreToolUse output. An allow sets no permissionDecision: an
    `allow` there would skip Claude's own permission check, and Claude applies
    an updatedInput without one."""
    match verdict:
        case Allow(context=context, updated_input=updated):
            rewrite: JsonObject = {} if updated is None else {"updatedInput": updated}
            return specific("PreToolUse", context, rewrite)
        case Deny(reason=reason, context=context):
            return specific(
                "PreToolUse",
                context,
                {"permissionDecision": "deny", "permissionDecisionReason": reason},
            )


def note_to_claude(event: Observed, note: Note) -> JsonObject:
    match event:
        case SessionStart():
            return specific("SessionStart", note.context, {})
        case AfterTool():
            return specific("PostToolUse", note.context, {})


def specific(event: str, context: str | None, fields: JsonObject) -> JsonObject:
    extra: JsonObject = {} if context is None else {"additionalContext": context}
    if not fields and not extra:
        return {}
    return {"hookSpecificOutput": {"hookEventName": event} | fields | extra}


if __name__ == "__main__":
    main()
