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
    AgentStart,
    AgentStop,
    Allow,
    BeforeTool,
    ContextSize,
    Deny,
    Harness,
    Json,
    JsonObject,
    Note,
    Observed,
    PromptExpansion,
    Role,
    SessionId,
    SessionStart,
    SkillName,
    Source,
    Tool,
    Verdict,
    emit_event,
    parse_event,
)
from claude_adapter import (
    TAIL_BYTES,
    ReadLines,
    note_to_claude,
    parse_claude,
    parse_tools,
    verdict_to_claude,
)
from recorded_events import recorded, recorded_all
from transcript_fixtures import (
    THINKING,
    assistant,
    bash,
    model_call,
    read,
    tool_result,
    write_transcript,
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
        "prompt": "Fuel: Max",
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
RECORDED_STARTS = recorded_all("SubagentStart")
RECORDED_EXPANSIONS = recorded_all("UserPromptExpansion")
RECORDED_STOPS = recorded_all("SubagentStop")
RECORDED_LEAD_STOPS = recorded_all("Stop")
SUBAGENT_START = recorded("SubagentStart")
TYPED_SKILL = recorded("UserPromptExpansion")
# The lead's stop, as Claude Code's hooks docs show it: no agent_id, and the
# session's background tasks, a shell and a finished agent among them.
LEAD_STOP: JsonObject = {
    **COMMON,
    "hook_event_name": "Stop",
    "stop_hook_active": False,
    "background_tasks": [
        {"id": "b1", "type": "subagent", "status": "running", "agent_type": "fixer"},
        {"id": "b2", "type": "subagent", "status": "completed"},
        {"id": "s1", "type": "shell", "status": "running"},
    ],
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


NO_USAGE: JsonObject = {
    "input_tokens": 0,
    "cache_read_input_tokens": 0,
    "cache_creation_input_tokens": 0,
}


@pytest.mark.parametrize(
    ("lines", "context"),
    [
        pytest.param(
            [
                *model_call("a", 148_000, bash("t1", "ls")),
                *model_call("b", 150_000, bash("t2", "ls"), read("t3")),
            ],
            ContextSize(150_000, 148_000),
            id="a call of several lines counts once",
        ),
        pytest.param(
            [
                *model_call("a", 148_000, bash("t1", "ls")),
                *model_call("b", 150_000, bash("t2", "ls")),
                b'{"type": "assis',
            ],
            ContextSize(150_000, 148_000),
            id="a partial last line is skipped",
        ),
        pytest.param(
            [
                *model_call("a", 148_000, bash("t1", "ls")),
                *model_call("t", 150_000),
                *model_call("b", 151_000, bash("t2", "ls")),
            ],
            ContextSize(151_000, 148_000),
            id="a text-only reply is no previous call",
        ),
        pytest.param(
            [
                *model_call("a", 150_000, bash("t1", "ls")),
                assistant("c", NO_USAGE, bash("t2", "ls")),
                *model_call("b", 150_000, bash("t3", "ls")),
            ],
            ContextSize(150_000, 150_000),
            id="an empty synthetic call is skipped",
        ),
        pytest.param(
            [
                *model_call("a", 148_000, bash("t1", "ls")),
                *model_call("b", 150_000, THINKING, bash("t2", "ls")),
                *model_call("c", 151_000, bash("t3", "ls")),
            ],
            ContextSize(151_000, 150_000),
            id="a call's text line does not hide its tool call",
        ),
    ],
)
def test_the_context_counts_model_calls_that_ran_a_tool(
    lines: list[JsonObject | bytes], context: ContextSize
) -> None:
    raw = [
        line if isinstance(line, bytes) else json.dumps(line).encode() for line in lines
    ]

    def disk(path: Path) -> list[bytes]:
        return raw if path == WORKER_TRANSCRIPT else []

    event = parse_claude(RAN, TOOLS, disk)

    assert isinstance(event, AfterTool)
    assert event.context == context


def test_a_subagent_is_not_judged_on_the_leads_context() -> None:
    disk = transcripts({MAIN_TRANSCRIPT: model_call("m1", 150_000, bash("t1", "ls"))})

    event = parse_claude(RAN, TOOLS, disk)

    assert isinstance(event, AfterTool)
    assert event.context is None


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


def test_a_session_start_reads_its_source_transcript_and_model() -> None:
    assert parse_claude(SESSION_START, TOOLS, NO_TRANSCRIPT) == SessionStart(
        SessionId("abc123"),
        Path("/work/repo"),
        None,
        Source.COMPACT,
        Harness("claude-code"),
        Path("/home/u/.claude/projects/p/abc123.jsonl"),
        "claude-opus-5-5",
    )


def test_a_session_start_naming_no_model_has_none() -> None:
    payload = {k: v for k, v in SESSION_START.items() if k != "model"}

    event = parse_claude(payload, TOOLS, NO_TRANSCRIPT)

    assert isinstance(event, SessionStart)
    assert event.model is None


@pytest.mark.parametrize("payload", RECORDED_STARTS)
def test_a_recorded_subagent_start_is_that_subagent_starting(
    payload: JsonObject,
) -> None:
    assert parse_claude(payload, TOOLS, NO_TRANSCRIPT) == AgentStart(
        SessionId(cast("str", payload["session_id"])),
        Path(cast("str", payload["cwd"])),
        Agent(
            AgentId(cast("str", payload["agent_id"])),
            Role(cast("str", payload["agent_type"])),
        ),
    )


@pytest.mark.parametrize("payload", RECORDED_EXPANSIONS)
def test_a_recorded_typed_skill_is_its_command_name(payload: JsonObject) -> None:
    assert parse_claude(payload, TOOLS, NO_TRANSCRIPT) == PromptExpansion(
        SessionId(cast("str", payload["session_id"])),
        Path(cast("str", payload["cwd"])),
        None,
        SkillName(cast("str", payload["command_name"])),
    )


@pytest.mark.parametrize("payload", RECORDED_STOPS)
def test_a_recorded_subagent_stop_is_that_subagent_stopping(
    payload: JsonObject,
) -> None:
    event = parse_claude(payload, TOOLS, NO_TRANSCRIPT)

    assert isinstance(event, AgentStop)
    assert event.agent == Agent(
        AgentId(cast("str", payload["agent_id"])),
        Role(cast("str", payload["agent_type"])),
    )


def test_a_background_agent_still_runs_at_its_own_recorded_stop() -> None:
    launch = next(
        payload
        for payload in recorded_all("PostToolUse")
        if payload["tool_name"] == "Agent"
        and (spawn := cast("JsonObject", payload["tool_input"]))["subagent_type"]
        == "probe-child"
        and spawn.get("run_in_background") is True
    )
    child = cast("dict[str, str]", launch["tool_response"])["agentId"]
    stop = next(payload for payload in RECORDED_STOPS if payload["agent_id"] == child)

    event = parse_claude(stop, TOOLS, NO_TRANSCRIPT)

    assert isinstance(event, AgentStop)
    assert event.running == (AgentId(child),)


@pytest.mark.parametrize("payload", RECORDED_LEAD_STOPS)
def test_a_recorded_stop_is_the_lead_stopping(payload: JsonObject) -> None:
    event = parse_claude(payload, TOOLS, NO_TRANSCRIPT)

    assert isinstance(event, AgentStop)
    assert event.agent is None


def test_the_leads_stop_has_no_agent_and_its_running_background_agents() -> None:
    assert parse_claude(LEAD_STOP, TOOLS, NO_TRANSCRIPT) == AgentStop(
        SessionId("abc123"), Path("/work/repo"), None, (AgentId("b1"),)
    )


def test_a_stop_with_no_background_tasks_has_none_running() -> None:
    payload = {k: v for k, v in LEAD_STOP.items() if k != "background_tasks"}

    assert parse_claude(payload, TOOLS, NO_TRANSCRIPT) == AgentStop(
        SessionId("abc123"), Path("/work/repo"), None, ()
    )


@pytest.mark.parametrize(
    "payload",
    [
        *RECORDED_STARTS,
        *RECORDED_EXPANSIONS,
        *RECORDED_STOPS,
        *RECORDED_LEAD_STOPS,
        SESSION_START,
        SPAWN,
        RAN,
        LEAD_STOP,
    ],
)
def test_an_event_the_adapter_reads_reaches_a_hook_unchanged(
    payload: JsonObject,
) -> None:
    event = parse_claude(payload, TOOLS, NO_TRANSCRIPT)

    assert parse_event(emit_event(event)) == event


def test_a_lead_tool_call_has_no_agent() -> None:
    assert parse_claude(SPAWN, TOOLS, NO_TRANSCRIPT) == BeforeTool(
        SessionId("abc123"),
        Path("/work/repo"),
        None,
        Tool.DELEGATE,
        {
            "description": "Implement slice 1",
            "prompt": "Fuel: Max",
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


def test_a_subagent_claude_names_no_id_is_a_subagent_with_no_id() -> None:
    event = parse_claude(HANDBACK | {"agent_id": None}, TOOLS, NO_TRANSCRIPT)

    assert event.agent == Agent(None, None)


def every_path_holds(lines: list[JsonObject]) -> ReadLines:
    """A fake disk where any path reads as `lines`."""
    return lambda _: [json.dumps(line).encode() for line in lines]


def test_a_subagent_with_no_id_carries_no_history() -> None:
    disk = every_path_holds(WORKER_SO_FAR)

    event = parse_claude(SHELL_CALL | {"agent_id": None}, TOOLS, disk)

    assert isinstance(event, BeforeTool)
    assert event.history == ()


def test_a_subagent_with_no_id_carries_no_context() -> None:
    disk = every_path_holds(WORKER_SO_FAR)

    event = parse_claude(RAN | {"agent_id": None}, TOOLS, disk)

    assert isinstance(event, AfterTool)
    assert event.context is None


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
            SESSION_START | {"transcript_path": "p/abc123.jsonl"},
            "not an absolute transcript path",
            id="relative transcript path",
        ),
        pytest.param(
            COMMON | {"hook_event_name": "Notification"},
            "not a SessionStart",
            id="unknown event",
        ),
        pytest.param(
            LEAD_STOP | {"background_tasks": "b1"},
            "background_tasks 'b1' is not a list",
            id="background tasks not a list",
        ),
        pytest.param(
            SPAWN | {"agent_id": "a1", "agent_type": 7},
            "agent_type 7 is not a string",
            id="agent type not a string",
        ),
        pytest.param(
            SPAWN | {"agent_id": 7, "agent_type": "implementer"},
            "agent_id 7 is not a string",
            id="agent id not a string",
        ),
        pytest.param(
            {k: v for k, v in SUBAGENT_START.items() if k != "agent_id"},
            "names no agent_id",
            id="subagent start with no agent",
        ),
        pytest.param(
            {k: v for k, v in TYPED_SKILL.items() if k != "command_name"},
            "not a SessionStart",
            id="typed skill with no name",
        ),
    ],
)
def test_a_payload_outside_the_contract_is_an_error(payload: Json, error: str) -> None:
    with pytest.raises(ValueError, match=error):
        _ = parse_claude(payload, TOOLS, NO_TRANSCRIPT)


START_EVENT = parse_claude(SESSION_START, TOOLS, NO_TRANSCRIPT)
RAN_EVENT = parse_claude(RAN, TOOLS, NO_TRANSCRIPT)
SUBAGENT_START_EVENT = parse_claude(SUBAGENT_START, TOOLS, NO_TRANSCRIPT)
TYPED_SKILL_EVENT = parse_claude(TYPED_SKILL, TOOLS, NO_TRANSCRIPT)


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
        pytest.param(
            SUBAGENT_START_EVENT,
            Note("brief"),
            {
                "hookSpecificOutput": {
                    "hookEventName": "SubagentStart",
                    "additionalContext": "brief",
                }
            },
            id="context at a subagent's start",
        ),
        pytest.param(
            TYPED_SKILL_EVENT,
            Note("begin"),
            {
                "hookSpecificOutput": {
                    "hookEventName": "UserPromptExpansion",
                    "additionalContext": "begin",
                }
            },
            id="context beside a typed skill",
        ),
        pytest.param(SUBAGENT_START_EVENT, Note(), {}, id="nothing at a start"),
        pytest.param(
            parse_claude(RECORDED_STOPS[0], TOOLS, NO_TRANSCRIPT),
            Note("go on"),
            {},
            id="no context at a subagent's stop",
        ),
        pytest.param(
            parse_claude(LEAD_STOP, TOOLS, NO_TRANSCRIPT),
            Note("go on"),
            {},
            id="no context at the lead's stop",
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
            Allow("advice", {"prompt": "Fuel: Max\nDiff: /tmp/d"}),
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "updatedInput": {"prompt": "Fuel: Max\nDiff: /tmp/d"},
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
                "prompt": "Fuel: Max\nDiff: /tmp/d",
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
    done = adapter(tmp_path, {}, COMMON | {"hook_event_name": "Notification"})

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


def test_the_built_adapter_hands_a_starting_subagents_hook_its_agent(
    tmp_path: Path,
) -> None:
    done = adapter(tmp_path, {"agentStart": [echo("agent")]}, SUBAGENT_START)

    assert echoed(done) == {
        "id": SUBAGENT_START["agent_id"],
        "role": SUBAGENT_START["agent_type"],
    }


def test_the_built_adapter_hands_a_typed_skills_hook_its_name(
    tmp_path: Path,
) -> None:
    done = adapter(tmp_path, {"promptExpansion": [echo("skill")]}, TYPED_SKILL)

    assert echoed(done) == TYPED_SKILL["command_name"]


def test_the_built_adapter_runs_an_agent_stops_hook_and_lets_the_agent_stop(
    tmp_path: Path,
) -> None:
    seen = tmp_path / "seen.json"
    record = (
        "import sys; open(sys.argv[1], 'w').write(sys.stdin.read());"
        ' print(\'{"context": "go on"}\')'
    )
    hook: JsonObject = {
        "name": "ended",
        "tools": None,
        "command": [sys.executable, "-c", record, str(seen)],
    }

    done = adapter(tmp_path, {"agentStop": [hook]}, LEAD_STOP)

    assert done.returncode == 0, done.stderr
    assert json.loads(done.stdout) == {}
    assert json.loads(seen.read_text()) == {
        "event": "agentStop",
        "session": "abc123",
        "cwd": "/work/repo",
        "agent": None,
        "running": ["b1"],
    }


@pytest.mark.parametrize(
    ("event", "payload"),
    [("agentStart", SUBAGENT_START), ("promptExpansion", TYPED_SKILL)],
)
def test_the_built_adapter_tells_a_deny_at_an_event_with_no_tool_and_never_denies(
    tmp_path: Path, event: str, payload: JsonObject
) -> None:
    manifest: JsonObject = {
        event: [declared("no", None, 'print(\'{"decision": "deny", "reason": "no"}\')')]
    }

    done = adapter(tmp_path, manifest, payload)

    assert done.returncode == 0, done.stderr
    specific = cast("dict[str, JsonObject]", json.loads(done.stdout))[
        "hookSpecificOutput"
    ]
    assert specific == {
        "hookEventName": payload["hook_event_name"],
        "additionalContext": "hook no: bad output: only beforeTool may set ['decision', 'reason']",
    }
