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
    ContextSize,
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
from claude_adapter import (
    TAIL_BYTES,
    ReadLines,
    note_to_claude,
    parse_claude,
    parse_tools,
    verdict_to_claude,
)

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


# ---- Transcripts, as Claude Code writes them: one line per content block ----------

MAIN_TRANSCRIPT = Path("/home/u/.claude/projects/p/abc123.jsonl")
WORKER_TRANSCRIPT = Path("/home/u/.claude/projects/p/abc123/subagents/agent-a1b2.jsonl")


def transcripts(by_path: dict[Path, list[JsonObject]]) -> ReadLines:
    """A fake disk: each path's lines; any other path cannot be read."""
    return lambda path: [json.dumps(line).encode() for line in by_path.get(path, [])]


NO_TRANSCRIPT = transcripts({})


THINKING: JsonObject = {"type": "text", "text": "thinking aloud"}


def model_call(message_id: str, tokens: int, *blocks: JsonObject) -> list[JsonObject]:
    """A model call's lines, its usage split as Claude splits it."""
    usage: JsonObject = {
        "input_tokens": 3,
        "cache_read_input_tokens": tokens - 13,
        "cache_creation_input_tokens": 10,
        "output_tokens": 99,
    }
    return [assistant(message_id, usage, block) for block in blocks or [THINKING]]


def assistant(message_id: str, usage: JsonObject, block: Json) -> JsonObject:
    return {
        "type": "assistant",
        "message": {"id": message_id, "usage": usage, "content": [block]},
    }


def bash(use_id: str, command: str) -> JsonObject:
    return {
        "type": "tool_use",
        "id": use_id,
        "name": "Bash",
        "input": {"command": command},
    }


def read(use_id: str) -> JsonObject:
    return {
        "type": "tool_use",
        "id": use_id,
        "name": "Read",
        "input": {"file_path": "/a"},
    }


def tool_result(use_id: str) -> JsonObject:
    return {
        "type": "user",
        "message": {"content": [{"type": "tool_result", "tool_use_id": use_id}]},
    }


SHELL_CALL: JsonObject = {
    **COMMON,
    **WORKER,
    "hook_event_name": "PreToolUse",
    "tool_name": "Bash",
    "tool_input": {"command": "gh pr checks 7"},
    "tool_use_id": "toolu_09",
}
WORKER_SO_FAR = [
    *model_call("m1", 40_000, bash("toolu_05", "git status"), read("toolu_06")),
    tool_result("toolu_05"),
    *model_call("m2", 60_000, bash("toolu_07", "gh pr checks 7")),
    tool_result("toolu_07"),
    *model_call("m3", 70_000, bash("toolu_09", "gh pr checks 7")),
]


def test_a_shell_call_carries_the_agents_earlier_commands_oldest_first() -> None:
    disk = transcripts({WORKER_TRANSCRIPT: WORKER_SO_FAR})

    event = parse_claude(SHELL_CALL, TOOLS, disk)

    assert isinstance(event, BeforeTool)
    assert event.history == ("git status", "gh pr checks 7")


def test_the_lead_reads_its_history_from_the_main_transcript() -> None:
    lead_call = {k: v for k, v in SHELL_CALL.items() if k not in WORKER}
    disk = transcripts(
        {MAIN_TRANSCRIPT: model_call("m1", 1_000, bash("toolu_01", "ls"))}
    )

    event = parse_claude(lead_call, TOOLS, disk)

    assert isinstance(event, BeforeTool)
    assert event.history == ("ls",)


def test_a_call_other_than_shell_carries_no_history() -> None:
    disk = transcripts({MAIN_TRANSCRIPT: WORKER_SO_FAR})

    event = parse_claude(SPAWN, TOOLS, disk)

    assert isinstance(event, BeforeTool)
    assert event.history == ()


def test_a_tool_result_carries_the_newest_context_and_the_last_that_ran_a_tool() -> (
    None
):
    so_far = [
        *WORKER_SO_FAR,
        tool_result("toolu_09"),
        *model_call("m4", 90_000),
        *model_call("m5", 155_000, read("toolu_10"), bash("toolu_11", "ls")),
    ]
    disk = transcripts({WORKER_TRANSCRIPT: so_far})

    event = parse_claude(RAN, TOOLS, disk)

    assert isinstance(event, AfterTool)
    assert event.context == ContextSize(155_000, 70_000)


def test_the_first_call_has_no_previous_context() -> None:
    disk = transcripts({WORKER_TRANSCRIPT: model_call("m1", 20_000, bash("t1", "ls"))})

    event = parse_claude(RAN, TOOLS, disk)

    assert isinstance(event, AfterTool)
    assert event.context == ContextSize(20_000, None)


@pytest.mark.parametrize(
    "payload",
    [
        pytest.param(RAN, id="unreadable transcript"),
        pytest.param(
            {k: v for k, v in RAN.items() if k != "transcript_path"},
            id="no transcript path",
        ),
    ],
)
def test_no_transcript_gives_no_context(payload: JsonObject) -> None:
    event = parse_claude(payload, TOOLS, NO_TRANSCRIPT)

    assert isinstance(event, AfterTool)
    assert event.context is None


def test_a_session_start_reads_its_source() -> None:
    assert parse_claude(SESSION_START, TOOLS, NO_TRANSCRIPT) == SessionStart(
        SessionId("abc123"), Path("/work/repo"), None, Source.COMPACT
    )


def test_a_lead_tool_call_has_no_agent() -> None:
    assert parse_claude(SPAWN, TOOLS, NO_TRANSCRIPT) == BeforeTool(
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
    event = parse_claude(HANDBACK, TOOLS, NO_TRANSCRIPT)

    assert event == BeforeTool(
        SessionId("abc123"),
        Path("/work/repo"),
        Agent(AgentId("a1b2"), Role("implementer")),
        Tool.HANDBACK,
        {"message": "READY commit abc"},
    )


def test_a_tool_result_carries_its_output() -> None:
    match parse_claude(RAN, TOOLS, NO_TRANSCRIPT):
        case AfterTool(tool=Tool.SHELL, output={"stdout": str(stdout)}):
            assert stdout.endswith("/pull/7\n")
        case event:
            raise AssertionError(event)


@pytest.mark.parametrize("name", ["WebFetch", "WebSearch"])
def test_a_vendor_free_name_covers_each_of_its_claude_tools(name: str) -> None:
    event = parse_claude(
        SPAWN | {"tool_name": name, "tool_input": {}}, TOOLS, NO_TRANSCRIPT
    )

    assert isinstance(event, BeforeTool)
    assert event.tool == Tool.WEB


def test_a_tool_with_no_vendor_free_name_is_other() -> None:
    event = parse_claude(
        RAN | {"tool_name": "mcp__github__get_pr", "tool_input": {}},
        TOOLS,
        NO_TRANSCRIPT,
    )

    assert isinstance(event, AfterTool)
    assert event.tool == Tool.OTHER


@pytest.mark.parametrize(
    "payload",
    [
        pytest.param(HANDBACK | {"agent_type": None}, id="null type"),
        pytest.param(
            {k: v for k, v in HANDBACK.items() if k != "agent_type"}, id="no type"
        ),
    ],
)
def test_a_subagent_with_no_type_has_no_role(payload: JsonObject) -> None:
    event = parse_claude(payload, TOOLS, NO_TRANSCRIPT)

    assert event.agent == Agent(AgentId("a1b2"), None)


def test_a_subagent_claude_names_no_id_is_an_unnamed_subagent() -> None:
    event = parse_claude(HANDBACK | {"agent_id": None}, TOOLS, NO_TRANSCRIPT)

    assert event.agent == Agent(AgentId("unnamed"), None)


def test_a_lead_started_as_an_agent_type_is_still_the_lead() -> None:
    event = parse_claude(
        SESSION_START | {"agent_type": "engineer"}, TOOLS, NO_TRANSCRIPT
    )

    assert isinstance(event, SessionStart)
    assert event.agent is None


@pytest.mark.parametrize(
    ("payload", "error"),
    [
        pytest.param(SESSION_START | {"source": "clear"}, "clear", id="unknown source"),
        pytest.param(
            COMMON | {"hook_event_name": "Stop"},
            "not a SessionStart",
            id="unknown event",
        ),
        pytest.param(
            SPAWN | {"agent_id": "a1", "agent_type": 7},
            "agent_type 7 is not a string",
            id="agent type not a string",
        ),
        pytest.param(
            SPAWN | {"agent_id": None, "agent_type": "implementer"},
            "agent_id None is not a string",
            id="agent id not a string",
        ),
    ],
)
def test_a_payload_outside_the_contract_is_an_error(payload: Json, error: str) -> None:
    with pytest.raises(ValueError, match=error):
        _ = parse_claude(payload, TOOLS, NO_TRANSCRIPT)


START_EVENT = parse_claude(SESSION_START, TOOLS, NO_TRANSCRIPT)
RAN_EVENT = parse_claude(RAN, TOOLS, NO_TRANSCRIPT)


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


ECHO = "import json, sys; e = json.load(sys.stdin); print(json.dumps({'context': json.dumps(e[sys.argv[1]])}))"


def echoed(done: subprocess.CompletedProcess[str]) -> Json:
    """What the echo hook saw of its event's field."""
    assert done.returncode == 0, done.stderr
    output = cast("dict[str, dict[str, str]]", json.loads(done.stdout))
    return cast("Json", json.loads(output["hookSpecificOutput"]["additionalContext"]))


def echo(field: str) -> JsonObject:
    return {
        "name": "echo",
        "tools": None,
        "command": [sys.executable, "-c", ECHO, field],
    }


def write_transcript(path: Path, lines: list[JsonObject], filler: int = 0) -> None:
    """Writes a transcript, after `filler` bytes of older lines when asked."""
    path.parent.mkdir(parents=True, exist_ok=True)
    old = model_call("m0", 1_000, bash("toolu_00", "make old")) if filler else []
    text = "".join(json.dumps(line) + "\n" for line in old)
    text += json.dumps({"type": "user", "pad": "x" * filler}) + "\n" if filler else ""
    _ = path.write_text(text + "".join(json.dumps(line) + "\n" for line in lines))


def at(tmp_path: Path, payload: JsonObject) -> JsonObject:
    return payload | {"transcript_path": str(tmp_path / "abc123.jsonl")}


def test_the_built_adapter_hands_a_subagents_hook_its_recent_shell_commands(
    tmp_path: Path,
) -> None:
    worker_transcript = tmp_path / "abc123" / "subagents" / "agent-a1b2.jsonl"
    write_transcript(worker_transcript, WORKER_SO_FAR, filler=TAIL_BYTES)

    done = adapter(
        tmp_path, {"beforeTool": [echo("history")]}, at(tmp_path, SHELL_CALL)
    )

    assert echoed(done) == ["git status", "gh pr checks 7"]


def test_the_built_adapter_hands_a_hook_the_context_after_any_tool(
    tmp_path: Path,
) -> None:
    write_transcript(
        tmp_path / "abc123" / "subagents" / "agent-a1b2.jsonl", WORKER_SO_FAR
    )
    mcp_ran = RAN | {"tool_name": "mcp__github__get_pr", "tool_input": {}}

    done = adapter(tmp_path, {"afterTool": [echo("context")]}, at(tmp_path, mcp_ran))

    assert echoed(done) == {"tokens": 70_000, "previous": 60_000}


def test_the_built_adapter_runs_the_hooks_without_a_transcript(tmp_path: Path) -> None:
    done = adapter(tmp_path, {"afterTool": [echo("context")]}, at(tmp_path, RAN))

    assert echoed(done) is None
