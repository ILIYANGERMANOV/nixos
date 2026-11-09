"""agent-hook-claude: Claude's hook JSON in, the neutral event to the hooks,
their folded result back as Claude's output. Payloads are shaped as Claude Code
sends them (https://code.claude.com/docs/en/hooks)."""

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import cast

import pytest
from agent_hook import (
    AfterTool,
    Agent,
    AgentId,
    Allow,
    BeforeTool,
    Deny,
    Json,
    JsonObject,
    Note,
    Observed,
    Role,
    SessionId,
    SessionStart,
    Source,
    Tool,
    Verdict,
)
from claude_adapter import note_to_claude, parse_claude, parse_tools, verdict_to_claude

# The built adapter and the tool table it is deployed with (codegen/tools.nix).
ADAPTER = os.environ["AGENT_HOOK_CLAUDE"]
TOOLS_FILE = os.environ["AGENT_HOOK_CLAUDE_TOOLS"]

TOOLS = parse_tools(
    json.dumps(
        {
            "shell": ["Bash"],
            "delegate": ["Agent"],
            "handback": ["SubagentHandback"],
            "web": ["WebFetch", "WebSearch"],
        }
    )
)

COMMON: JsonObject = {
    "session_id": "abc123",
    "transcript_path": "/home/u/.claude/projects/p/abc123.jsonl",
    "cwd": "/work/repo",
    "permission_mode": "default",
}
WORKER: JsonObject = {"agent_id": "a1b2", "agent_type": "implementer"}

SESSION_START: JsonObject = {
    **COMMON,
    "hook_event_name": "SessionStart",
    "source": "compact",
    "model": "claude-opus-5-5",
}
SPAWN: JsonObject = {
    **COMMON,
    "hook_event_name": "PreToolUse",
    "tool_name": "Agent",
    "tool_input": {
        "description": "Implement slice 1",
        "prompt": "Quality: Max",
        "subagent_type": "implementer",
    },
    "tool_use_id": "toolu_01",
}
HANDBACK: JsonObject = {
    **COMMON,
    **WORKER,
    "hook_event_name": "PreToolUse",
    "tool_name": "SubagentHandback",
    "tool_input": {"message": "READY commit abc"},
    "tool_use_id": "toolu_02",
}
RAN: JsonObject = {
    **COMMON,
    **WORKER,
    "hook_event_name": "PostToolUse",
    "tool_name": "Bash",
    "tool_input": {"command": "gh pr create --draft", "description": "Open the PR"},
    "tool_response": {
        "stdout": "https://github.com/o/r/pull/7\n",
        "stderr": "",
        "interrupted": False,
    },
    "tool_use_id": "toolu_03",
}


def test_a_session_start_reads_its_source() -> None:
    assert parse_claude(SESSION_START, TOOLS) == SessionStart(
        SessionId("abc123"), Path("/work/repo"), None, Source.COMPACT
    )


def test_a_lead_tool_call_has_no_agent() -> None:
    assert parse_claude(SPAWN, TOOLS) == BeforeTool(
        SessionId("abc123"),
        Path("/work/repo"),
        None,
        Tool.DELEGATE,
        {
            "description": "Implement slice 1",
            "prompt": "Quality: Max",
            "subagent_type": "implementer",
        },
    )


def test_a_subagent_is_its_id_and_its_type_as_role() -> None:
    event = parse_claude(HANDBACK, TOOLS)

    assert event == BeforeTool(
        SessionId("abc123"),
        Path("/work/repo"),
        Agent(AgentId("a1b2"), Role("implementer")),
        Tool.HANDBACK,
        {"message": "READY commit abc"},
    )


def test_a_tool_result_carries_its_output() -> None:
    match parse_claude(RAN, TOOLS):
        case AfterTool(tool=Tool.SHELL, output={"stdout": str(stdout)}):
            assert stdout.endswith("/pull/7\n")
        case event:
            raise AssertionError(event)


@pytest.mark.parametrize("name", ["WebFetch", "WebSearch"])
def test_a_vendor_free_name_covers_each_of_its_claude_tools(name: str) -> None:
    event = parse_claude(SPAWN | {"tool_name": name, "tool_input": {}}, TOOLS)

    assert isinstance(event, BeforeTool)
    assert event.tool == Tool.WEB


def test_a_lead_started_as_an_agent_type_is_still_the_lead() -> None:
    event = parse_claude(SESSION_START | {"agent_type": "engineer"}, TOOLS)

    assert isinstance(event, SessionStart)
    assert event.agent is None


@pytest.mark.parametrize(
    ("payload", "error"),
    [
        pytest.param(
            SPAWN | {"tool_name": "Grep"},
            "Grep has no vendor-free name",
            id="unmapped tool",
        ),
        pytest.param(SESSION_START | {"source": "clear"}, "clear", id="unknown source"),
        pytest.param(
            COMMON | {"hook_event_name": "Stop"},
            "not a SessionStart",
            id="unknown event",
        ),
        pytest.param(
            SPAWN | {"agent_id": "a1"},
            "without a string agent_type",
            id="agent without a type",
        ),
    ],
)
def test_a_payload_outside_the_contract_is_an_error(payload: Json, error: str) -> None:
    with pytest.raises(ValueError, match=error):
        _ = parse_claude(payload, TOOLS)


START_EVENT = parse_claude(SESSION_START, TOOLS)
RAN_EVENT = parse_claude(RAN, TOOLS)


@pytest.mark.parametrize(
    ("event", "note", "output"),
    [
        pytest.param(START_EVENT, Note(), {}, id="nothing to say"),
        pytest.param(
            START_EVENT,
            Note("resume here"),
            {
                "hookSpecificOutput": {
                    "hookEventName": "SessionStart",
                    "additionalContext": "resume here",
                }
            },
            id="context at start",
        ),
        pytest.param(
            RAN_EVENT,
            Note("recorded"),
            {
                "hookSpecificOutput": {
                    "hookEventName": "PostToolUse",
                    "additionalContext": "recorded",
                }
            },
            id="context after a tool",
        ),
    ],
)
def test_a_note_becomes_claudes_output(
    event: Observed, note: Note, output: JsonObject
) -> None:
    assert note_to_claude(event, note) == output


@pytest.mark.parametrize(
    ("verdict", "output"),
    [
        pytest.param(Allow(), {}, id="nothing to say"),
        pytest.param(
            Allow("advice", {"prompt": "Quality: Max\nDiff: /tmp/d"}),
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "updatedInput": {"prompt": "Quality: Max\nDiff: /tmp/d"},
                    "additionalContext": "advice",
                }
            },
            id="a rewrite sets no permission decision",
        ),
        pytest.param(
            Deny("not now", "why"),
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": "not now",
                    "additionalContext": "why",
                }
            },
            id="deny",
        ),
    ],
)
def test_a_verdict_becomes_claudes_output(verdict: Verdict, output: JsonObject) -> None:
    assert verdict_to_claude(verdict) == output


# End to end: the built adapter, its deployed tool table, real hooks.

PREPEND = """
import json, sys
event = json.load(sys.stdin)
prompt = event["input"]["prompt"]
print(json.dumps({"context": event["agent"] is None and "lead spawns" or "worker", "updatedInput": dict(event["input"], prompt=prompt + "\\nDiff: /tmp/d")}))
"""


def adapter(
    tmp_path: Path, manifest: JsonObject, payload: JsonObject
) -> subprocess.CompletedProcess[str]:
    manifest_file = tmp_path / "manifest.json"
    _ = manifest_file.write_text(json.dumps(manifest))
    return subprocess.run(
        [ADAPTER, TOOLS_FILE, str(manifest_file)],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        check=False,
    )


def declared(name: str, tools: list[Json] | None, code: str) -> JsonObject:
    return {"name": name, "tools": tools, "command": [sys.executable, "-c", code]}


def test_the_built_adapter_runs_an_events_hooks_and_answers_claude(
    tmp_path: Path,
) -> None:
    manifest: JsonObject = {
        "beforeTool": [
            declared("broken", None, "raise SystemExit(2)"),
            declared("diff", ["delegate"], PREPEND),
            declared(
                "shell-only",
                ["shell"],
                'print(\'{"decision": "deny", "reason": "no"}\')',
            ),
        ],
    }

    done = adapter(tmp_path, manifest, SPAWN)

    assert done.returncode == 0, done.stderr
    assert json.loads(done.stdout) == {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "updatedInput": {
                "description": "Implement slice 1",
                "prompt": "Quality: Max\nDiff: /tmp/d",
                "subagent_type": "implementer",
            },
            "additionalContext": "hook broken: exit 2: \n\nlead spawns",
        }
    }


def test_the_built_adapter_tells_a_deny_after_the_tool_ran_and_never_denies(
    tmp_path: Path,
) -> None:
    manifest: JsonObject = {
        "afterTool": [
            declared("late", None, 'print(\'{"decision": "deny", "reason": "no"}\')')
        ]
    }

    done = adapter(tmp_path, manifest, RAN)

    assert done.returncode == 0, done.stderr
    told = "hook late: bad output: only beforeTool may set ['decision', 'reason']"
    assert json.loads(done.stdout) == {
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": told,
        }
    }


DEPLOYED_TOOLS = [
    (name, claude_tool)
    for name, claude_tools in cast(
        "dict[str, list[str]]", json.loads(Path(TOOLS_FILE).read_text())
    ).items()
    for claude_tool in claude_tools
]


@pytest.mark.parametrize(("name", "claude_tool"), DEPLOYED_TOOLS)
def test_the_built_adapter_knows_every_tool_the_table_deploys(
    tmp_path: Path, name: str, claude_tool: str
) -> None:
    manifest: JsonObject = {
        "afterTool": [
            declared(
                "seen",
                None,
                "import json, sys; print(json.dumps({'context': json.load(sys.stdin)['tool']}))",
            )
        ]
    }

    done = adapter(tmp_path, manifest, RAN | {"tool_name": claude_tool})

    assert json.loads(done.stdout)["hookSpecificOutput"]["additionalContext"] == name


def test_the_built_adapter_refuses_what_it_cannot_read_and_lets_claude_go_on(
    tmp_path: Path,
) -> None:
    done = adapter(tmp_path, {}, COMMON | {"hook_event_name": "Stop"})

    assert done.returncode == 1
    assert done.stderr.startswith("agent-hook-claude: not a SessionStart")
    assert done.stdout == ""
