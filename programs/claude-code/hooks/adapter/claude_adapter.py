"""agent-hook-claude: Claude Code's side of the neutral hook contract.

    agent-hook-claude <tools.json> <manifest.json>

Claude runs it for every event a profile's hooks use. It turns Claude's hook
JSON into a neutral event, runs that event's hooks through the frontend's
dispatcher (agent_hook.py), and prints the folded result as Claude's output.
`tools.json` is codegen/tools.nix, Claude's tools by their vendor-free name;
the manifest is the hooks, each event's in order.

Input it cannot read exits 1 with the error on stderr: Claude shows it and lets
the call go on. A hook's own failure is the dispatcher's, and becomes context.
"""

import json
import sys
from collections.abc import Mapping
from pathlib import Path

from agent_hook import (
    AfterTool,
    Agent,
    AgentId,
    Allow,
    BeforeTool,
    Deny,
    Event,
    Json,
    JsonObject,
    Result,
    Role,
    SessionId,
    SessionStart,
    Source,
    Tool,
    as_list,
    as_str,
    dispatch,
    hooks_for,
    parse_json,
    parse_manifest,
    run_hook,
)

# Claude's tool name -> its vendor-free name.
type ToolNames = Mapping[str, Tool]


def main() -> None:
    try:
        tools_path, manifest_path = sys.argv[1:]
        tools = parse_tools(Path(tools_path).read_text())
        manifest = parse_manifest(Path(manifest_path).read_text())
        event = parse_claude(parse_json(sys.stdin.read()), tools)
    except ValueError as error:
        sys.exit(f"agent-hook-claude: {error}")
    print(
        json.dumps(
            to_claude(event, dispatch(hooks_for(manifest, event), event, run_hook))
        )
    )


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


def parse_claude(payload: Json, tools: ToolNames) -> Event:
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
            return BeforeTool(
                SessionId(session),
                Path(cwd),
                parse_agent(payload),
                vendor_free(tools, name),
                tool_input,
            )
        case {
            "hook_event_name": "PostToolUse",
            "session_id": str(session),
            "cwd": str(cwd),
            "tool_name": str(name),
            "tool_input": dict() as tool_input,
            "tool_response": output,
        }:
            return AfterTool(
                SessionId(session),
                Path(cwd),
                parse_agent(payload),
                vendor_free(tools, name),
                tool_input,
                output,
            )
        case _:
            raise ValueError("not a SessionStart, PreToolUse or PostToolUse event")


def parse_agent(payload: JsonObject) -> Agent | None:
    """Claude names a subagent by `agent_id` and its type; the lead has neither.
    A lead started with --agent has a type but no id: it is still the lead."""
    match payload:
        case {"agent_id": str(agent_id), "agent_type": str(role)}:
            return Agent(AgentId(agent_id), Role(role))
        case {"agent_id": agent_id}:
            raise ValueError(f"agent_id {agent_id!r} without a string agent_type")
        case _:
            return None


def vendor_free(tools: ToolNames, name: str) -> Tool:
    match tools.get(name):
        case None:
            raise ValueError(f"the tool {name} has no vendor-free name")
        case tool:
            return tool


def to_claude(event: Event, result: Result) -> JsonObject:
    """Claude's hook output. An allow sets no permissionDecision: an `allow`
    there would skip Claude's own permission check, and Claude applies an
    updatedInput without one."""
    match event, result:
        case SessionStart(), Allow(context=context):
            return specific("SessionStart", context, {})
        case BeforeTool(), Allow(context=context, updated_input=updated):
            rewrite: JsonObject = {} if updated is None else {"updatedInput": updated}
            return specific("PreToolUse", context, rewrite)
        case BeforeTool(), Deny(reason=reason, context=context):
            return specific(
                "PreToolUse",
                context,
                {"permissionDecision": "deny", "permissionDecisionReason": reason},
            )
        case AfterTool(), Allow(context=context):
            return specific("PostToolUse", context, {})
        case SessionStart() | AfterTool(), Deny():
            # parse_result refuses a deny on any event but beforeTool.
            raise AssertionError("only beforeTool may deny")


def specific(event: str, context: str | None, fields: JsonObject) -> JsonObject:
    extra: JsonObject = {} if context is None else {"additionalContext": context}
    if not fields and not extra:
        return {}
    return {"hookSpecificOutput": {"hookEventName": event} | fields | extra}


if __name__ == "__main__":
    main()
