"""agent-hook-opencode: the plugin's envelope in, the neutral events to the
hooks, their folded result back as what the plugin does."""

import contextlib
import json
import os
import subprocess
import sys
from collections.abc import Sequence
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
    CallId,
    ContextSize,
    Deny,
    Harness,
    Json,
    JsonObject,
    PromptExpansion,
    Role,
    SessionId,
    SessionStart,
    SkillName,
    Source,
    Tool,
    Usage,
    Verdict,
    emit_event,
    parse_event,
)
from hypothesis import given
from hypothesis import strategies as st
from json_strategies import json_objects, json_values
from opencode_adapter import (
    HARNESS,
    parse_opencode,
    parse_tools,
    verdict_to_opencode,
)
from plugin_envelopes import (
    CALL,
    CHILD,
    CWD,
    LEAD,
    after,
    before,
    call_tokens,
    envelope,
    in_child,
    task_output,
)

# The built adapters, and the tool tables they are deployed with.
ADAPTER = os.environ["AGENT_HOOK_OPENCODE"]
TOOLS_FILE = os.environ["AGENT_HOOK_OPENCODE_TOOLS"]
CLAUDE_ADAPTER = os.environ["AGENT_HOOK_CLAUDE"]
CLAUDE_TOOLS_FILE = os.environ["AGENT_HOOK_CLAUDE_TOOLS"]

TOOLS = parse_tools(Path(TOOLS_FILE).read_text())

SESSION = SessionId(LEAD)
WORKER = Agent(AgentId(CHILD), Role("implementer"))
CALLED = CallId(CALL)


# ---- Envelopes, as the plugin sends them --------------------------------------------


def message(
    parts: Sequence[Json] = (),
    running: Sequence[str] = (),
    *,
    first: bool = False,
    created: bool = True,
    spent: JsonObject | None = None,
) -> JsonObject:
    return envelope(
        "message",
        first=first,
        created=created,
        parts=[*parts],
        agents={CHILD: "implementer"},
        running=[*running],
        spent={} if spent is None else spent,
    )


SPAWN_ARGS: JsonObject = {
    "description": "Implement slice 1",
    "prompt": "Fuel: Max",
    "subagent_type": "implementer",
}


# ---- The tool table ------------------------------------------------------------------


def test_the_deployed_table_names_each_opencode_tool_once() -> None:
    assert TOOLS == {
        "bash": Tool.SHELL,
        "read": Tool.READ,
        "edit": Tool.EDIT,
        "apply_patch": Tool.EDIT,
        "write": Tool.WRITE,
        "webfetch": Tool.WEB,
        "websearch": Tool.WEB,
        "task": Tool.DELEGATE,
        "skill": Tool.SKILL,
    }


@pytest.mark.parametrize(
    "table",
    [
        "[]",
        '{"shell": ["bash"]}',
        '{"nope": {"tools": ["x"]}}',
        '{"shell": {"tools": "bash"}}',
    ],
)
def test_a_table_not_of_codegen_tools_shape_is_refused(table: str) -> None:
    with pytest.raises(ValueError):
        _ = parse_tools(table)


# ---- A tool call to judge ------------------------------------------------------------


@pytest.mark.parametrize(
    ("tool", "args", "neutral", "named"),
    [
        (
            "read",
            {"filePath": "/work/repo/a.py", "offset": 10, "limit": 50},
            Tool.READ,
            {"file_path": "/work/repo/a.py", "offset": 10, "limit": 50},
        ),
        (
            "edit",
            {
                "filePath": "a.py",
                "oldString": "x",
                "newString": "y",
                "replaceAll": True,
            },
            Tool.EDIT,
            {
                "file_path": "a.py",
                "old_string": "x",
                "new_string": "y",
                "replace_all": True,
            },
        ),
        (
            "write",
            {"filePath": "a.py", "content": "x"},
            Tool.WRITE,
            {"file_path": "a.py", "content": "x"},
        ),
        ("skill", {"name": "engineer"}, Tool.SKILL, {"skill": "engineer"}),
        (
            "task",
            SPAWN_ARGS | {"background": True},
            Tool.DELEGATE,
            SPAWN_ARGS | {"run_in_background": True},
        ),
        ("webfetch", {"url": "https://x.dev"}, Tool.WEB, {"url": "https://x.dev"}),
        ("glob", {"pattern": "*.py"}, Tool.OTHER, {"pattern": "*.py"}),
    ],
)
def test_a_tool_call_takes_its_vendor_free_name_and_claude_shaped_input(
    tool: str, args: JsonObject, neutral: Tool, named: JsonObject
) -> None:
    assert parse_opencode(before(tool, args), TOOLS) == BeforeTool(
        SESSION, CWD, None, neutral, named, harness=HARNESS, call=CALLED
    )


def test_a_shell_call_carries_the_sessions_earlier_commands() -> None:
    payload = before("bash", {"command": "gh run view 7"}, ["ls", "gh run view 7"])

    assert parse_opencode(payload, TOOLS) == BeforeTool(
        SESSION,
        CWD,
        None,
        Tool.SHELL,
        {"command": "gh run view 7"},
        ("ls", "gh run view 7"),
        harness=HARNESS,
        call=CALLED,
    )


def test_any_other_call_carries_no_history() -> None:
    event = parse_opencode(before("read", {"filePath": "a"}, ["ls"]), TOOLS)

    assert isinstance(event, BeforeTool)
    assert event.history == ()


@pytest.mark.parametrize(
    ("workdir", "cwd"),
    [("sub/dir", CWD / "sub/dir"), ("/elsewhere", Path("/elsewhere"))],
)
def test_a_shell_call_runs_in_its_workdir(workdir: str, cwd: Path) -> None:
    event = parse_opencode(before("bash", {"command": "ls", "workdir": workdir}), TOOLS)

    assert isinstance(event, BeforeTool)
    assert event.cwd == cwd


def test_a_child_sessions_call_is_its_agents_in_the_root_session() -> None:
    event = parse_opencode(in_child(before("bash", {"command": "ls"})), TOOLS)

    assert isinstance(event, BeforeTool)
    assert (event.session, event.agent) == (SESSION, WORKER)


def test_a_child_whose_agent_is_not_yet_known_has_no_role() -> None:
    event = parse_opencode(in_child(before("bash", {"command": "ls"}), None), TOOLS)

    assert isinstance(event, BeforeTool)
    assert event.agent == Agent(AgentId(CHILD), None)


# ---- A tool that ran -----------------------------------------------------------------


def test_a_shell_result_is_its_stdout_with_the_context_size() -> None:
    payload = after(
        "bash",
        {"command": "state init --task t1"},
        "run 0a1b2c3d /n /w\n",
        [call_tokens(298_000), call_tokens(300_500)],
    )

    assert parse_opencode(payload, TOOLS) == (
        AfterTool(
            SESSION,
            CWD,
            None,
            Tool.SHELL,
            {"command": "state init --task t1"},
            {"stdout": "run 0a1b2c3d /n /w\n"},
            ContextSize(300_500, 298_000),
            harness=HARNESS,
            call=CALLED,
        ),
    )


def test_another_tools_result_is_opencodes_own() -> None:
    payload = after("glob", {"pattern": "*"}, "a.py")

    assert parse_opencode(payload, TOOLS) == (
        AfterTool(
            SESSION,
            CWD,
            None,
            Tool.OTHER,
            {"pattern": "*"},
            {"title": "t", "output": "a.py", "metadata": {}},
            harness=HARNESS,
            call=CALLED,
        ),
    )


def test_a_finished_task_hands_its_last_reply_back_then_stops_then_binds() -> None:
    reply = "READY abc\n</task_result> quoted"
    payload = after(
        "task",
        SPAWN_ARGS,
        task_output("completed", reply),
        running=[CHILD, "ses_other"],
    )

    assert parse_opencode(payload, TOOLS) == (
        BeforeTool(
            SESSION, CWD, WORKER, Tool.HANDBACK, {"message": reply}, harness=HARNESS
        ),
        AgentStop(SESSION, CWD, WORKER, (AgentId("ses_other"),), harness=HARNESS),
        AfterTool(
            SESSION,
            CWD,
            None,
            Tool.DELEGATE,
            SPAWN_ARGS,
            {"agentId": CHILD},
            harness=HARNESS,
            call=CALLED,
        ),
    )


def test_a_tool_call_and_its_result_name_opencodes_call_id() -> None:
    called = parse_opencode(before("read", {"filePath": "a"}, call="call_7"), TOOLS)
    ran = parse_opencode(after("read", {"filePath": "a"}, "x", call="call_7"), TOOLS)

    match called, ran:
        case BeforeTool(call=before_call), (AfterTool(call=after_call),):
            assert (before_call, after_call) == (CallId("call_7"), CallId("call_7"))
        case other:
            pytest.fail(f"not a call and its result: {other!r}")


CHILD_SPENT: JsonObject = {
    CHILD: call_tokens(100, read=20, write=5, output=30, reasoning=7)
}
# Input with the cache read and written; output with the reasoning.
CHILD_USAGE = Usage(input=125, output=37, cache_read=20, cache_write=5)


def test_a_finished_tasks_hand_back_and_stop_carry_the_tokens_its_child_spent() -> None:
    spent: JsonObject = {**CHILD_SPENT, "ses_other": call_tokens(9_000)}
    payload = after(
        "task", SPAWN_ARGS, task_output("completed", "READY abc"), spent=spent
    )

    match parse_opencode(payload, TOOLS):
        case (BeforeTool(usage=handed), AgentStop(usage=stopped), AfterTool()):
            assert (handed, stopped) == (CHILD_USAGE, CHILD_USAGE)
        case other:
            pytest.fail(f"not a hand-back, a stop and an afterTool: {other!r}")


def test_a_failed_tasks_stop_carries_the_tokens_its_child_spent() -> None:
    payload = after("task", SPAWN_ARGS, task_output("error", "boom"), spent=CHILD_SPENT)

    match parse_opencode(payload, TOOLS):
        case (AgentStop(usage=usage), AfterTool()):
            assert usage == CHILD_USAGE
        case other:
            pytest.fail(f"not a stop then an afterTool: {other!r}")


def test_a_background_tasks_end_carries_the_tokens_its_child_spent() -> None:
    text = task_output("completed", "READY abc", "Background task completed: slice 1")
    parts: list[Json] = [{"type": "text", "synthetic": True, "text": text}]

    match parse_opencode(message(parts=parts, spent=CHILD_SPENT), TOOLS):
        case (BeforeTool(usage=handed), AgentStop(usage=stopped)):
            assert (handed, stopped) == (CHILD_USAGE, CHILD_USAGE)
        case other:
            pytest.fail(f"not a hand-back then a stop: {other!r}")


def test_a_child_the_plugin_saw_no_model_call_of_has_no_usage() -> None:
    payload = after("task", SPAWN_ARGS, task_output("completed", "READY abc"))

    match parse_opencode(payload, TOOLS):
        case (BeforeTool(usage=handed), AgentStop(usage=stopped), AfterTool()):
            assert (handed, stopped) == (None, None)
        case other:
            pytest.fail(f"not a hand-back, a stop and an afterTool: {other!r}")


def test_a_background_task_started_only_binds() -> None:
    payload = after(
        "task",
        SPAWN_ARGS | {"background": True},
        task_output("running", "started", "Background task started"),
    )

    match parse_opencode(payload, TOOLS):
        case (AfterTool(output=output),):
            assert output == {"agentId": CHILD}
        case other:
            pytest.fail(f"not one afterTool: {other!r}")


def test_a_failed_task_stops_with_no_hand_back() -> None:
    payload = after("task", SPAWN_ARGS, task_output("error", "boom"))

    match parse_opencode(payload, TOOLS):
        case (AgentStop(agent=agent, running=()), AfterTool()):
            assert agent == WORKER
        case other:
            pytest.fail(f"not a stop then an afterTool: {other!r}")


def test_a_task_output_that_is_no_task_block_is_refused() -> None:
    with pytest.raises(ValueError, match="no <task> block"):
        _ = parse_opencode(after("task", SPAWN_ARGS, "done"), TOOLS)


# ---- Messages, commands, stops -------------------------------------------------------


@pytest.mark.parametrize(
    ("created", "source"), [(True, Source.STARTUP), (False, Source.RESUME)]
)
def test_the_leads_first_message_starts_an_opencode_session_with_no_transcript(
    created: bool,  # noqa: FBT001 - a parameter of the test
    source: Source,
) -> None:
    assert parse_opencode(message(first=True, created=created), TOOLS) == (
        SessionStart(SESSION, CWD, None, source, Harness("opencode"), None, None),
    )


@pytest.mark.parametrize("created", [True, False])
def test_a_child_sessions_first_message_starts_the_agent(
    created: bool,  # noqa: FBT001 - a parameter of the test
) -> None:
    payload = in_child(message(first=True, created=created))

    assert parse_opencode(payload, TOOLS) == (
        AgentStart(SESSION, CWD, WORKER, harness=HARNESS),
    )


def test_a_later_message_starts_nothing() -> None:
    assert parse_opencode(message(first=False, created=False), TOOLS) == ()


def test_a_background_tasks_end_in_the_parents_message_hands_back_and_stops() -> None:
    text = task_output("completed", "READY abc", "Background task completed: slice 1")
    parts: list[Json] = [{"type": "text", "synthetic": True, "text": text}]

    assert parse_opencode(message(parts=parts, running=[CHILD]), TOOLS) == (
        BeforeTool(
            SESSION,
            CWD,
            WORKER,
            Tool.HANDBACK,
            {"message": "READY abc"},
            harness=HARNESS,
        ),
        AgentStop(SESSION, CWD, WORKER, (), harness=HARNESS),
    )


@pytest.mark.parametrize(
    "part",
    [
        {"type": "text", "text": task_output("completed", "typed by a person")},
        {"type": "text", "synthetic": True, "text": "Called the read tool"},
        {"type": "file", "synthetic": True, "url": "file:///a"},
    ],
)
def test_any_other_part_of_a_later_message_tells_nothing(part: JsonObject) -> None:
    assert parse_opencode(message(parts=[part]), TOOLS) == ()


def test_a_command_expands_a_skill() -> None:
    assert parse_opencode(envelope("command", command="engineer"), TOOLS) == (
        PromptExpansion(SESSION, CWD, None, SkillName("engineer"), harness=HARNESS),
    )


def test_the_root_going_idle_stops_the_lead_with_its_running_children() -> None:
    assert parse_opencode(envelope("idle", running=[CHILD]), TOOLS) == (
        AgentStop(SESSION, CWD, None, (AgentId(CHILD),), harness=HARNESS),
    )


def test_a_child_going_idle_stops_nothing() -> None:
    assert parse_opencode(in_child(envelope("idle", running=[])), TOOLS) == ()


# ---- A model call's context --------------------------------------------------------


def context_of(tokens: Sequence[Json]) -> ContextSize | None:
    match parse_opencode(after("glob", {}, "x", tokens), TOOLS):
        case (AfterTool(context=context),):
            return context
        case other:
            pytest.fail(f"not one afterTool: {other!r}")


def test_the_context_is_the_newest_calls_input_and_cache_after_the_one_before() -> None:
    tokens = [
        call_tokens(9),
        call_tokens(100, read=20, write=3, output=50),
        call_tokens(200, read=40, write=5, output=60),
    ]

    assert context_of(tokens) == ContextSize(245, 123)


def test_a_call_with_no_tokens_counted_yet_is_skipped() -> None:
    tokens = [call_tokens(100), call_tokens(200), call_tokens(0)]

    assert context_of(tokens) == ContextSize(200, 100)


@pytest.mark.parametrize(
    ("tokens", "context"),
    [
        ([], None),
        ([call_tokens(0)], None),
        ([call_tokens(100)], ContextSize(100, None)),
    ],
)
def test_a_session_with_fewer_than_two_counted_calls_has_less_context(
    tokens: list[Json], context: ContextSize | None
) -> None:
    assert context_of(tokens) == context


# ---- apply_patch, OpenCode's edit on gpt- models -----------------------------------


def patch(*lines: str) -> JsonObject:
    return {"patchText": "\n".join(["*** Begin Patch", *lines, "*** End Patch"])}


@pytest.mark.parametrize(
    "lines",
    [
        ["*** Add File: notes.md", "+*** Delete File: other.md"],
        ["*** Update File: notes.md", "@@", "-a", "+b"],
        ["*** Delete File:notes.md"],
        [
            "*** Update File: notes.md",
            "@@",
            " *** Add File: other.md",
            "*** Update File: notes.md",
        ],
    ],
)
def test_a_patch_of_one_file_is_an_edit_of_it(lines: list[str]) -> None:
    args = patch(*lines)

    assert parse_opencode(before("apply_patch", args), TOOLS) == BeforeTool(
        SESSION,
        CWD,
        None,
        Tool.EDIT,
        args | {"file_path": "notes.md"},
        harness=HARNESS,
        call=CALLED,
    )


@pytest.mark.parametrize(
    "lines",
    [
        ["*** Add File: a.md", "+x", "*** Delete File: b.md"],
        ["*** Update File: a.md", "*** Move to: b.md", "@@", "-a", "+b"],
        [],
    ],
)
def test_a_patch_of_several_files_or_none_is_an_edit_of_no_one_file(
    lines: list[str],
) -> None:
    args = patch(*lines)

    assert parse_opencode(before("apply_patch", args), TOOLS) == BeforeTool(
        SESSION, CWD, None, Tool.EDIT, args, harness=HARNESS, call=CALLED
    )


@pytest.mark.parametrize(
    "payload",
    [
        [],
        {
            k: v
            for k, v in before("bash", {"command": "ls"}).items()
            if k != "directory"
        },
        envelope("halt", running=[]),
        in_child(envelope("idle", running=[])) | {"agent": 3},
        {
            k: v
            for k, v in in_child(envelope("idle", running=[])).items()
            if k != "agent"
        },
        message() | {"first": "yes"},
        message() | {"created": None},
        before("bash", {"command": "ls"}) | {"history": [3]},
        after("bash", {"command": "ls"}, "x", [{"input": "many"}]),
        after("bash", {"command": "ls"}, "x", [call_tokens(1) | {"cache": {}}]),
        after(
            "task",
            SPAWN_ARGS,
            task_output("completed", "READY abc"),
            spent={CHILD: {"input": 1}},
        ),
        before("bash", {"command": "ls"}) | {"callID": None},
    ],
)
def test_an_envelope_it_cannot_read_is_refused(payload: Json) -> None:
    with pytest.raises(ValueError):
        _ = parse_opencode(payload, TOOLS)


# ---- What the plugin does -------------------------------------------------------------


@pytest.mark.parametrize(
    ("verdict", "output"),
    [
        (Allow(), {}),
        (Allow("note"), {"context": "note"}),
        (Deny("no"), {"deny": "no"}),
        (Deny("no", "see the docs"), {"deny": "no\n\nsee the docs"}),
        (
            Allow(None, {"file_path": "b.py", "limit": 20}),
            {"args": {"filePath": "b.py", "limit": 20}},
        ),
    ],
)
def test_a_verdict_becomes_what_the_plugin_does(
    verdict: Verdict, output: JsonObject
) -> None:
    assert verdict_to_opencode(verdict, Tool.READ) == output


# ---- Properties -------------------------------------------------------------------------

tool_names = st.sampled_from(sorted(TOOLS)) | st.text()
ids = st.text(min_size=1)
counts = st.integers(min_value=0)


def text_part(synthetic: bool, text: str) -> Json:  # noqa: FBT001 - a builder's field
    return {"type": "text", "synthetic": synthetic, "text": text}


def child_caller(child: str, agent: str | None) -> JsonObject:
    return {"sessionID": child, "agent": agent}


def task_ran(output: str, running: list[str], spent: JsonObject) -> JsonObject:
    return after("task", SPAWN_ARGS, output, (), running, spent=spent)


def command(name: str) -> JsonObject:
    return envelope("command", command=name)


def idle(running: list[str]) -> JsonObject:
    return envelope("idle", running=[*running])


def message_of(
    parts: list[Json],
    running: list[str],
    first: bool,  # noqa: FBT001 - a builder's field
    created: bool,  # noqa: FBT001 - a builder's field
    spent: JsonObject,
) -> JsonObject:
    return message(parts, running, first=first, created=created, spent=spent)


def called_by(shape: JsonObject, caller: JsonObject) -> JsonObject:
    return shape | caller


tokens_lists = st.lists(st.builds(call_tokens, counts, counts, counts, counts))
spents = st.dictionaries(
    st.sampled_from([CHILD, "ses_other"]),
    st.builds(call_tokens, counts, counts, counts, counts, counts),
)
task_texts = st.builds(
    task_output,
    st.sampled_from(["running", "completed", "error"]),
    st.text(),
    st.none() | st.text(alphabet=st.characters(exclude_characters="<")),
)
parts = st.lists(
    st.builds(text_part, st.booleans(), task_texts | st.text()), max_size=3
)
callers = st.just(cast("JsonObject", {})) | st.builds(
    child_caller, ids.filter(lambda child: child != LEAD), st.none() | st.text()
)
well_formed = st.builds(
    called_by,
    st.one_of(
        st.builds(
            before, tool_names, json_objects, st.lists(st.text()), call=st.text()
        ),
        st.builds(
            after,
            tool_names.filter(lambda tool: tool != "task"),
            json_objects,
            st.text(),
            tokens_lists,
            st.lists(ids),
            call=st.text(),
        ),
        st.builds(task_ran, task_texts, st.lists(ids), spents),
        st.builds(
            message_of, parts, st.lists(ids), st.booleans(), st.booleans(), spents
        ),
        st.builds(command, st.text()),
        st.builds(idle, st.lists(ids)),
    ),
    callers,
)


@given(well_formed)
def test_every_envelope_gives_events_the_hooks_read_back_as_sent(
    payload: JsonObject,
) -> None:
    asked = parse_opencode(payload, TOOLS)

    events = (asked,) if isinstance(asked, BeforeTool) else asked
    assert [parse_event(emit_event(event)) for event in events] == list(events)


unnamed_tools = st.text().filter(lambda name: name not in TOOLS)


@given(
    st.builds(
        called_by,
        st.builds(before, unnamed_tools, json_objects, st.lists(st.text()))
        | st.builds(
            after, unnamed_tools, json_objects, st.text(), tokens_lists, st.lists(ids)
        ),
        callers,
    )
)
def test_a_tool_the_table_does_not_name_is_other(payload: JsonObject) -> None:
    match parse_opencode(payload, TOOLS):
        case BeforeTool(tool=tool) | (AfterTool(tool=tool),):
            assert tool == Tool.OTHER
        case other:
            pytest.fail(f"no tool event: {other!r}")


# Every field an envelope may carry.
FIELDS = [
    "hook",
    "sessionID",
    "rootID",
    "agent",
    "directory",
    "tool",
    "args",
    "callID",
    "history",
    "output",
    "tokens",
    "running",
    "spent",
    "first",
    "created",
    "parts",
    "agents",
    "command",
]


@given(well_formed, st.sampled_from(FIELDS), json_values)
def test_any_envelope_parses_or_is_refused_cleanly(
    payload: JsonObject, field: str, value: Json
) -> None:
    broken = payload | {field: value}

    with contextlib.suppress(ValueError):
        _ = parse_opencode(broken, TOOLS)


@given(st.text(min_size=1), st.none() | st.text(min_size=1), st.sampled_from(Tool))
def test_a_deny_keeps_its_reason(reason: str, context: str | None, tool: Tool) -> None:
    told = verdict_to_opencode(Deny(reason, context), tool)

    assert cast("str", told["deny"]).startswith(reason)


neutral_inputs = st.dictionaries(
    st.sampled_from(
        [
            "file_path",
            "old_string",
            "limit",
            "skill",
            "subagent_type",
            "run_in_background",
            "command",
        ]
    ),
    json_values,
)


@given(st.sampled_from(sorted(TOOLS)), neutral_inputs)
def test_a_rewrite_reaches_opencode_as_the_input_the_hooks_wrote(
    tool: str, rewritten: JsonObject
) -> None:
    args = verdict_to_opencode(Allow(None, rewritten), TOOLS[tool])["args"]

    event = parse_opencode(before(tool, cast("JsonObject", args)), TOOLS)

    assert isinstance(event, BeforeTool)
    assert event.input == rewritten


# ---- The built adapter ---------------------------------------------------------------------


def run(
    adapter: str, tools: str, tmp_path: Path, manifest: JsonObject, payload: JsonObject
) -> subprocess.CompletedProcess[str]:
    manifest_file = tmp_path / "manifest.json"
    _ = manifest_file.write_text(json.dumps(manifest))
    return subprocess.run(
        [adapter, tools, str(manifest_file)],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        check=False,
    )


def opencode(tmp_path: Path, manifest: JsonObject, payload: JsonObject) -> JsonObject:
    done = run(ADAPTER, TOOLS_FILE, tmp_path, manifest, payload)
    assert (done.returncode, done.stderr) == (0, ""), done.stderr
    return cast("JsonObject", json.loads(done.stdout))


def declared(name: str, tools: list[Json] | None, code: str) -> JsonObject:
    return {"name": name, "tools": tools, "command": [sys.executable, "-c", code]}


TELL_TOOL = "import json, sys; e = json.load(sys.stdin); print(json.dumps({'context': e['tool']}))"
TELL_EVENT = "import json, sys; e = json.load(sys.stdin); print(json.dumps({'context': e['event']}))"
# Denies with the event it read, its harness aside: the one key that tells the backends apart.
DENY_WITH_EVENT = "import json, sys; e = json.load(sys.stdin); del e['harness']; print(json.dumps({'decision': 'deny', 'reason': json.dumps(e)}))"
LIMIT = """
import json, sys
event = json.load(sys.stdin)
print(json.dumps({"context": "bounded", "updatedInput": dict(event["input"], limit=200)}))
"""


def test_the_built_adapter_rewrites_a_call_in_opencodes_names(tmp_path: Path) -> None:
    manifest: JsonObject = {
        "beforeTool": [
            declared("broken", None, "raise SystemExit(2)"),
            declared("limit", ["read"], LIMIT),
        ]
    }

    told = opencode(tmp_path, manifest, before("read", {"filePath": "/w/a.py"}))

    assert told == {
        "args": {"filePath": "/w/a.py", "limit": 200},
        "context": "hook broken: exit 2: \n\nbounded",
    }


def test_the_built_adapter_denies_with_the_reason(tmp_path: Path) -> None:
    manifest: JsonObject = {
        "beforeTool": [
            declared("no", ["shell"], 'print(\'{"decision": "deny", "reason": "no"}\')')
        ]
    }

    assert opencode(tmp_path, manifest, before("bash", {"command": "ls"})) == {
        "deny": "no"
    }


def test_the_built_adapter_tells_the_parent_of_a_task_but_not_the_hand_back(
    tmp_path: Path,
) -> None:
    manifest: JsonObject = {
        "beforeTool": [declared("handback", ["handback"], TELL_EVENT)],
        "agentStop": [declared("stop", None, TELL_EVENT)],
        "afterTool": [declared("bind", ["delegate"], TELL_TOOL)],
    }
    payload = after("task", SPAWN_ARGS, task_output("completed", "READY abc"))

    assert opencode(tmp_path, manifest, payload) == {"context": "delegate"}


def test_the_built_adapter_joins_the_notes_of_a_message(tmp_path: Path) -> None:
    manifest: JsonObject = {
        "sessionStart": [declared("start", None, TELL_EVENT)],
        "beforeTool": [declared("handback", ["handback"], TELL_EVENT)],
    }
    text = task_output("completed", "READY abc", "Background task completed: x")
    payload = message(
        [{"type": "text", "synthetic": True, "text": text}], first=True, created=True
    )

    assert opencode(tmp_path, manifest, payload) == {"context": "sessionStart"}


@pytest.mark.parametrize(("opencode_tool", "name"), sorted(TOOLS.items()))
def test_the_built_adapter_knows_every_tool_the_table_deploys(
    tmp_path: Path, opencode_tool: str, name: Tool
) -> None:
    manifest: JsonObject = {"beforeTool": [declared("seen", None, TELL_TOOL)]}

    told = opencode(tmp_path, manifest, before(opencode_tool, {}))

    assert told == {"context": name.value}


def test_the_built_adapter_refuses_what_it_cannot_read_and_lets_opencode_go_on(
    tmp_path: Path,
) -> None:
    done = run(ADAPTER, TOOLS_FILE, tmp_path, {}, envelope("halt"))

    assert done.returncode == 1
    assert done.stderr.startswith("agent-hook-opencode: not a before, after")
    assert done.stdout == ""


# ---- Differential: the same call through Claude Code's adapter -------------------------


# The same call, as each agent sends it: its tool and input.
SAME_CALLS: list[tuple[tuple[str, JsonObject], tuple[str, JsonObject]]] = [
    (
        ("Read", {"file_path": "/w/a.py", "limit": 50}),
        ("read", {"filePath": "/w/a.py", "limit": 50}),
    ),
    (
        ("Edit", {"file_path": "/w/a.py", "old_string": "x", "new_string": "y"}),
        ("edit", {"filePath": "/w/a.py", "oldString": "x", "newString": "y"}),
    ),
    (
        ("Write", {"file_path": "/w/a.py", "content": "x"}),
        ("write", {"filePath": "/w/a.py", "content": "x"}),
    ),
    (
        ("Bash", {"command": "sleep 60", "timeout": 1000}),
        ("bash", {"command": "sleep 60", "timeout": 1000}),
    ),
    (
        ("Agent", SPAWN_ARGS | {"run_in_background": True}),
        ("task", SPAWN_ARGS | {"background": True}),
    ),
    (("Skill", {"skill": "engineer"}), ("skill", {"name": "engineer"})),
]
# The same caller: the lead, or a subagent.
SAME_CALLERS: list[tuple[JsonObject, JsonObject]] = [
    ({}, {}),
    (
        {"agent_id": CHILD, "agent_type": "implementer"},
        {"sessionID": CHILD, "agent": "implementer"},
    ),
]


@pytest.mark.parametrize(("claude_call", "opencode_call"), SAME_CALLS)
@pytest.mark.parametrize(("claude_caller", "opencode_caller"), SAME_CALLERS)
def test_the_same_call_reaches_the_hooks_and_is_denied_as_in_claude_code(
    tmp_path: Path,
    claude_call: tuple[str, JsonObject],
    opencode_call: tuple[str, JsonObject],
    claude_caller: JsonObject,
    opencode_caller: JsonObject,
) -> None:
    # A hook denying with the event it read: the reasons match when both the
    # events and the verdicts do.
    manifest: JsonObject = {"beforeTool": [declared("echo", None, DENY_WITH_EVENT)]}
    claude_payload: JsonObject = {
        "session_id": LEAD,
        "cwd": str(CWD),
        "hook_event_name": "PreToolUse",
        "tool_name": claude_call[0],
        "tool_input": claude_call[1],
        "tool_use_id": CALL,
        **claude_caller,
    }
    payload = before(*opencode_call) | opencode_caller

    claude = run(CLAUDE_ADAPTER, CLAUDE_TOOLS_FILE, tmp_path, manifest, claude_payload)
    denied = opencode(tmp_path, manifest, payload)

    claude_output = cast("dict[str, JsonObject]", json.loads(claude.stdout))
    claude_reason = claude_output["hookSpecificOutput"]["permissionDecisionReason"]
    assert denied == {"deny": claude_reason}


# ---- Differential: a spawn's whole life through both adapters ---------------------------

# One real Claude Code run (contract/live.py), as its hooks received it.
LIVE_RUN = cast(
    "list[JsonObject]",
    json.loads(
        (
            Path(__file__).parents[2]
            / "claude-code/hooks/contract/fixtures/live-run.json"
        ).read_text()
    )["events"],
)
# Appends each event a hook reads to the file its argument names.
RECORD = "import sys; open(sys.argv[1], 'a').write(sys.stdin.read() + '\\n')"


def recorded_event(event: str, **fields: Json) -> JsonObject:
    return next(
        payload
        for payload in LIVE_RUN
        if payload["hook_event_name"] == event
        and all(payload.get(key) == value for key, value in fields.items())
    )


def recorder(log: Path) -> JsonObject:
    hook = declared("record", None, RECORD)
    hook["command"] = [*cast("list[Json]", hook["command"]), str(log)]
    return {"beforeTool": [hook], "afterTool": [hook], "agentStop": [hook]}


def comparable(line: str) -> JsonObject:
    """An event as the kernel reads it, but for what differs by harness alone:
    the harness, the transcript (OpenCode writes none), a spawn's output but
    for `agentId` (Claude's has its own fields), and a hand-back's call
    (OpenCode's is no tool call, so it names none)."""
    event = cast("JsonObject", json.loads(line))
    del event["harness"], event["transcript_path"]
    match event:
        case {"tool": "delegate", "output": {"agentId": child}}:
            return event | {"output": {"agentId": child}}
        case {"tool": "handback"}:
            return {key: value for key, value in event.items() if key != "call"}
        case _:
            return event


def test_a_foreground_spawn_reaches_the_hooks_as_in_claude_code(tmp_path: Path) -> None:
    # Claude: the lead's spawn, the child's hand-back and stop, then the
    # spawn's result, which binds the child; its transcript has two requests.
    spawn = recorded_event("PreToolUse", tool_name="Agent", agent_id=None)
    call = cast("str", spawn["tool_use_id"])
    bind = recorded_event("PostToolUse", tool_use_id=call)
    child = cast("str", cast("JsonObject", bind["tool_response"])["agentId"])
    handback = recorded_event(
        "PreToolUse", tool_name="SubagentHandback", agent_id=child
    )
    stop = recorded_event("SubagentStop", agent_id=child)
    main = tmp_path / "main.jsonl"
    child_transcript = main.with_suffix("") / "subagents" / f"agent-{child}.jsonl"
    child_transcript.parent.mkdir(parents=True)
    requests = [
        ("msg_1", 2, 5_093, 2_748, 325),
        ("msg_2", 4, 100, 50, 10),
    ]
    _ = child_transcript.write_text(
        "".join(
            json.dumps(
                {
                    "type": "assistant",
                    "message": {
                        "id": message_id,
                        "usage": {
                            "input_tokens": fresh,
                            "cache_read_input_tokens": read,
                            "cache_creation_input_tokens": written,
                            "output_tokens": output,
                        },
                        "content": [],
                    },
                }
            )
            + "\n"
            for message_id, fresh, read, written, output in requests
        )
    )
    claude_log = tmp_path / "claude.log"
    for payload in [spawn, handback, stop, bind]:
        done = run(
            CLAUDE_ADAPTER,
            CLAUDE_TOOLS_FILE,
            tmp_path,
            recorder(claude_log),
            payload | {"transcript_path": str(main)},
        )
        assert done.returncode == 0, done.stderr

    # OpenCode: the same spawn, and its task's result, which holds the rest.
    # Derived from the Claude recording, not recorded itself: no real OpenCode
    # session could be recorded where this was written. It pins that both
    # adapters agree, not that this is the input OpenCode sends.
    session = cast("str", spawn["session_id"])
    lead: JsonObject = {"sessionID": session, "rootID": session}
    directory = Path(cast("str", spawn["cwd"]))
    args = renamed_back(cast("JsonObject", spawn["tool_input"]))
    report = cast("str", cast("JsonObject", handback["tool_input"])["message"])
    spent = call_tokens(6, read=5_193, write=2_798, output=300, reasoning=35)
    opencode_log = tmp_path / "opencode.log"
    for payload in [
        before("task", args, directory=directory, call=call),
        after(
            "task",
            args,
            task_output("completed", report, child=child),
            directory=directory,
            call=call,
            spent={child: spent},
        ),
    ]:
        _ = opencode(tmp_path, recorder(opencode_log), payload | lead)

    claude_events = claude_log.read_text().splitlines()
    opencode_events = opencode_log.read_text().splitlines()
    assert len(claude_events) == 4
    assert list(map(comparable, opencode_events)) == list(
        map(comparable, claude_events)
    )


def renamed_back(claude_input: JsonObject) -> JsonObject:
    """A spawn's input in OpenCode's names: the adapter renames them back."""
    return {
        "background" if key == "run_in_background" else key: value
        for key, value in claude_input.items()
    }
