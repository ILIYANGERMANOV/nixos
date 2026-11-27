"""The neutral hook contract and its dispatcher: events and results survive the
wire, results fold as a monoid, and a hook that fails never blocks a call."""

import json
import sys
from dataclasses import replace
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
    Event,
    EventName,
    EveryTool,
    Harness,
    Hook,
    HookName,
    Json,
    Note,
    Observed,
    PromptExpansion,
    Role,
    SessionId,
    SessionStart,
    SkillName,
    Source,
    Tool,
    Usage,
    Verdict,
    combine_notes,
    combine_verdicts,
    dispatch_note,
    dispatch_verdict,
    emit_event,
    emit_result,
    event_name,
    hooks_for,
    parse_event,
    parse_manifest,
    parse_note,
    parse_verdict,
    run_note_hook,
    run_verdict_hook,
)
from hypothesis import given
from hypothesis import strategies as st
from json_strategies import json_objects, json_values

VOCABULARY = Path(__file__).with_name("vocabulary.json")

SESSION = SessionId("s1")
CWD = Path("/work/repo")
WORKER = Agent(AgentId("a1"), Role("implementer"))
START = SessionStart(
    SESSION,
    CWD,
    None,
    Source.RESUME,
    Harness("claude-code"),
    Path("/home/u/.claude/projects/p/s1.jsonl"),
    "claude-opus-5-5",
)
CLAUDE = Harness("claude-code")
TRANSCRIPT = Path("/home/u/.claude/projects/p/s1.jsonl")
SPAWN = BeforeTool(
    SESSION, CWD, None, Tool.DELEGATE, {"prompt": "brief"}, harness=CLAUDE
)
RAN = AfterTool(
    SESSION, CWD, WORKER, Tool.SHELL, {"command": "ls"}, "a\nb\n", harness=CLAUDE
)
STARTED = AgentStart(SESSION, CWD, WORKER, harness=CLAUDE)
TYPED = PromptExpansion(SESSION, CWD, None, SkillName("engineer"), harness=CLAUDE)
STOPPED = AgentStop(
    SESSION, CWD, WORKER, (AgentId("a1"), AgentId("a2")), harness=CLAUDE
)
# The wire's keys every event carries.
COMMON = {
    "session": "s1",
    "cwd": "/work/repo",
    "harness": "claude-code",
    "transcript_path": None,
}

texts = st.text(min_size=1)
subagents = st.builds(
    Agent, st.none() | st.text().map(AgentId), st.none() | st.text().map(Role)
)
agents = st.none() | subagents
counts = st.integers(min_value=0)
context_sizes = st.none() | st.builds(ContextSize, counts, st.none() | counts)
paths = st.text(alphabet="abc/", min_size=1).map(lambda p: Path("/" + p))
# A transcript path as the kernel takes it: absolute and normalised.
transcripts = st.lists(st.text(alphabet="abc", min_size=1)).map(
    lambda parts: Path("/" + "/".join(parts))
)
sessions = st.text().map(SessionId)
harnesses = texts.map(Harness)
calls = st.none() | st.text().map(CallId)
usages = st.none() | st.builds(
    Usage, st.none() | counts, st.none() | counts, st.none() | counts, st.none() | counts
)
events: st.SearchStrategy[Event] = st.one_of(
    st.builds(
        SessionStart,
        sessions,
        paths,
        agents,
        st.sampled_from(Source),
        harnesses,
        st.none() | transcripts,
        st.none() | texts,
    ),
    st.builds(
        BeforeTool,
        sessions,
        paths,
        agents,
        st.sampled_from(Tool),
        json_objects,
        st.lists(st.text()).map(tuple),
        harness=harnesses,
        transcript=st.none() | transcripts,
        call=calls,
        usage=usages,
    ),
    st.builds(
        AfterTool,
        sessions,
        paths,
        agents,
        st.sampled_from(Tool),
        json_objects,
        json_values,
        context_sizes,
        harness=harnesses,
        transcript=st.none() | transcripts,
        call=calls,
    ),
    st.builds(
        AgentStart,
        sessions,
        paths,
        subagents,
        harness=harnesses,
        transcript=st.none() | transcripts,
    ),
    st.builds(
        PromptExpansion,
        sessions,
        paths,
        agents,
        st.text().map(SkillName),
        harness=harnesses,
        transcript=st.none() | transcripts,
    ),
    st.builds(
        AgentStop,
        sessions,
        paths,
        agents,
        st.lists(st.text().map(AgentId)).map(tuple),
        harness=harnesses,
        transcript=st.none() | transcripts,
        usage=usages,
    ),
)
contexts = st.none() | texts
verdicts: st.SearchStrategy[Verdict] = st.one_of(
    st.builds(Allow, contexts, st.none() | json_objects),
    st.builds(Deny, texts.filter(str.strip), contexts),
)
notes = st.builds(Note, contexts)


EVERY_TOOL = EveryTool()


def hook(name: str, tools: frozenset[Tool] | EveryTool = EVERY_TOOL) -> Hook:
    return Hook(HookName(name), tools, (name,))


def python(
    name: str, code: str, tools: frozenset[Tool] | EveryTool = EVERY_TOOL
) -> Hook:
    """A real hook: a Python program the dispatcher spawns."""
    return Hook(HookName(name), tools, (sys.executable, "-c", code))


# The wire.


def test_the_enums_hold_the_vocabulary_nix_reads() -> None:
    vocabulary = cast("dict[str, list[str]]", json.loads(VOCABULARY.read_text()))

    assert [e.value for e in EventName] == vocabulary["events"]
    assert [t.value for t in Tool] == vocabulary["tools"]
    assert [s.value for s in Source] == vocabulary["sources"]


@given(events)
def test_an_emitted_event_parses_back_to_itself(event: Event) -> None:
    assert parse_event(emit_event(event)) == event


# A wire every event's keys make valid, short of its own.
ANY: dict[str, Json] = {
    "session": "s",
    "cwd": "/",
    "agent": None,
    "harness": "claude-code",
    "transcript_path": None,
}
BEFORE_SHELL: dict[str, Json] = ANY | {
    "event": "beforeTool",
    "tool": "shell",
    "call": None,
    "input": {},
    "history": [],
    "usage": None,
}
AFTER_SHELL: dict[str, Json] = ANY | {
    "event": "afterTool",
    "tool": "shell",
    "call": None,
    "input": {},
    "output": "",
    "context": None,
}
SESSION_START: dict[str, Json] = ANY | {
    "event": "sessionStart",
    "source": "startup",
    "request_model": None,
}
AGENT_STOP: dict[str, Json] = ANY | {"event": "agentStop", "running": [], "usage": None}


def without(wire: dict[str, Json], key: str) -> Json:
    return {k: v for k, v in wire.items() if k != key}


@pytest.mark.parametrize(
    "wire",
    [
        pytest.param(ANY | {"event": "beforeLunch"}, id="unknown event"),
        pytest.param(BEFORE_SHELL | {"tool": "teleport"}, id="unknown tool"),
        pytest.param(SESSION_START | {"source": "clear"}, id="unknown source"),
        pytest.param(
            SESSION_START | {"transcript_path": "projects/s.jsonl"},
            id="relative transcript path",
        ),
        pytest.param(
            BEFORE_SHELL | {"transcript_path": "projects/s.jsonl"},
            id="relative transcript path off a session start",
        ),
        pytest.param(without(SESSION_START, "harness"), id="session start with no harness"),
        pytest.param(without(BEFORE_SHELL, "harness"), id="before a tool with no harness"),
        pytest.param(
            without(AGENT_STOP, "transcript_path"), id="agent stop with no transcript key"
        ),
        pytest.param(BEFORE_SHELL | {"agent": {"id": "a"}}, id="agent without a role"),
        pytest.param(ANY | {"event": "agentStart"}, id="agent start with no agent"),
        pytest.param(
            ANY | {"event": "promptExpansion"}, id="prompt expansion with no skill"
        ),
        pytest.param(without(AGENT_STOP, "running"), id="agent stop with no running list"),
        pytest.param(AGENT_STOP | {"running": [7]}, id="running id not a string"),
        pytest.param(without(BEFORE_SHELL, "history"), id="no history"),
        pytest.param(without(BEFORE_SHELL, "call"), id="before a tool with no call key"),
        pytest.param(without(AFTER_SHELL, "call"), id="after a tool with no call key"),
        pytest.param(BEFORE_SHELL | {"call": 7}, id="call not a string"),
        pytest.param(without(BEFORE_SHELL, "usage"), id="before a tool with no usage key"),
        pytest.param(without(AGENT_STOP, "usage"), id="agent stop with no usage key"),
        pytest.param(
            AGENT_STOP | {"usage": {"input_tokens": -1}}, id="negative token count"
        ),
        pytest.param(
            AGENT_STOP | {"usage": {"input_tokens": "12k"}}, id="token count not a count"
        ),
        pytest.param(
            AGENT_STOP | {"usage": {"total_tokens": 12}}, id="usage with an unknown count"
        ),
        pytest.param(
            AFTER_SHELL | {"context": {"tokens": "150k", "previous": None}},
            id="context not a count",
        ),
    ],
)
def test_an_event_outside_the_contract_is_an_error(wire: Json) -> None:
    with pytest.raises(ValueError):
        _ = parse_event(json.dumps(wire))


def test_an_event_reads_as_the_wire_names_it() -> None:
    wire = COMMON | {
        "event": "afterTool",
        "tool": "shell",
        "call": "toolu_01",
        "input": {"command": "ls"},
        "output": "a\nb\n",
        "agent": {"id": "a1", "role": "implementer"},
        "context": {"tokens": 150_000, "previous": None},
    }

    assert parse_event(json.dumps(wire)) == replace(
        RAN, context=ContextSize(150_000, None), call=CallId("toolu_01")
    )


def test_a_hand_back_reads_its_usage_a_count_left_out_staying_unknown() -> None:
    wire = COMMON | {
        "event": "beforeTool",
        "agent": {"id": "a1", "role": "implementer"},
        "transcript_path": str(TRANSCRIPT),
        "tool": "handback",
        "call": "toolu_02",
        "input": {"message": "READY"},
        "history": [],
        "usage": {"input_tokens": 1200, "cache_read_input_tokens": 1000},
    }

    assert parse_event(json.dumps(wire)) == BeforeTool(
        SESSION,
        CWD,
        WORKER,
        Tool.HANDBACK,
        {"message": "READY"},
        harness=CLAUDE,
        transcript=TRANSCRIPT,
        call=CallId("toolu_02"),
        usage=Usage(input=1200, cache_read=1000),
    )


def test_a_count_left_out_is_left_out_on_the_wire_never_zero() -> None:
    event = replace(STOPPED, usage=Usage(output=0))

    assert json.loads(emit_event(event))["usage"] == {"output_tokens": 0}


def test_a_session_start_reads_as_the_wire_names_it() -> None:
    wire = COMMON | {
        "event": "sessionStart",
        "agent": None,
        "source": "resume",
        "transcript_path": "/home/u/.claude/projects/p/s1.jsonl",
        "request_model": "claude-opus-5-5",
    }

    assert parse_event(json.dumps(wire)) == START


def session_start_at(transcript: str) -> Json:
    return COMMON | {
        "event": "sessionStart",
        "agent": None,
        "source": "resume",
        "transcript_path": transcript,
        "request_model": "claude-opus-5-5",
    }


# The paths the kernel's absPath takes and refuses, as GHC's filepath `normalise` decides.
@pytest.mark.parametrize("path", ["/a/b", "/a/../b", "/a/b/", "/"])
def test_a_session_start_takes_a_transcript_path_the_kernel_takes(path: str) -> None:
    assert parse_event(json.dumps(session_start_at(path))) == replace(
        START, transcript=Path(path)
    )


@pytest.mark.parametrize("path", ["//a/b", "/a//b", "/a/./b", "/a/b/."])
def test_a_session_start_refuses_a_transcript_path_the_kernel_refuses(
    path: str,
) -> None:
    with pytest.raises(ValueError):
        _ = parse_event(json.dumps(session_start_at(path)))


def test_a_session_start_with_no_transcript_or_model_reads_none() -> None:
    wire = COMMON | {
        "event": "sessionStart",
        "agent": None,
        "source": "resume",
        "harness": "opencode",
        "request_model": None,
    }

    assert parse_event(json.dumps(wire)) == replace(
        START, harness=Harness("opencode"), transcript=None, model=None
    )


def test_a_subagent_start_reads_as_the_wire_names_it() -> None:
    wire = COMMON | {
        "event": "agentStart",
        "agent": {"id": "a1", "role": "implementer"},
    }

    assert parse_event(json.dumps(wire)) == STARTED


def test_a_typed_skill_reads_as_the_wire_names_it() -> None:
    wire = COMMON | {"event": "promptExpansion", "agent": None, "skill": "engineer"}

    assert parse_event(json.dumps(wire)) == TYPED


def test_an_agent_stop_reads_as_the_wire_names_it() -> None:
    wire = COMMON | {
        "event": "agentStop",
        "agent": {"id": "a1", "role": "implementer"},
        "running": ["a1", "a2"],
        "usage": None,
    }

    assert parse_event(json.dumps(wire)) == STOPPED


def test_a_subagent_its_agent_names_no_role_reads_as_one_with_no_role() -> None:
    wire = COMMON | {
        "event": "beforeTool",
        "tool": "shell",
        "call": None,
        "input": {"command": "ls"},
        "agent": {"id": "a1", "role": None},
        "history": ["git status"],
        "usage": None,
    }

    assert parse_event(json.dumps(wire)) == BeforeTool(
        SESSION,
        CWD,
        Agent(AgentId("a1"), None),
        Tool.SHELL,
        {"command": "ls"},
        ("git status",),
        harness=CLAUDE,
    )


def test_a_subagent_its_agent_gives_no_id_reads_as_one_with_no_id() -> None:
    event = BeforeTool(
        SESSION,
        CWD,
        Agent(None, Role("implementer")),
        Tool.SHELL,
        {"command": "ls"},
        harness=CLAUDE,
    )

    assert json.loads(emit_event(event))["agent"] == {"id": None, "role": "implementer"}
    assert parse_event(emit_event(event)) == event


@given(verdicts)
def test_an_emitted_verdict_parses_back_to_itself(verdict: Verdict) -> None:
    assert parse_verdict(emit_result(verdict)) == verdict


@given(notes)
def test_an_emitted_note_parses_back_to_itself(note: Note) -> None:
    assert parse_note(emit_result(note)) == note


@pytest.mark.parametrize("printed", ["", "  \n"])
def test_printing_nothing_before_a_tool_allows(printed: str) -> None:
    assert parse_verdict(printed) == Allow()


@pytest.mark.parametrize("printed", ["", "  \n"])
def test_printing_nothing_otherwise_notes_nothing(printed: str) -> None:
    assert parse_note(printed) == Note()


@pytest.mark.parametrize(
    ("printed", "error"),
    [
        pytest.param(
            '{"decision": "deny"}', "needs a reason", id="deny without a reason"
        ),
        pytest.param(
            '{"decision": "deny", "reason": "no", "updatedInput": {}}',
            "rewrites no input",
            id="deny rewriting",
        ),
        pytest.param(
            '{"reason": "why"}', "only a deny has a reason", id="allow with a reason"
        ),
        pytest.param(
            '{"decision": "maybe"}', "unknown decision", id="unknown decision"
        ),
        pytest.param('{"updated_input": {}}', "unknown field", id="misspelled field"),
        pytest.param(
            '{"updatedInput": "x"}', "not an object", id="input not an object"
        ),
        pytest.param('{"context": 1}', "not a string", id="context not a string"),
        pytest.param("[]", "not a JSON object", id="not an object"),
    ],
)
def test_a_verdict_outside_the_contract_is_an_error(printed: str, error: str) -> None:
    with pytest.raises(ValueError, match=error):
        _ = parse_verdict(printed)


@pytest.mark.parametrize(
    ("printed", "error"),
    [
        pytest.param(
            '{"decision": "deny", "reason": "no"}',
            r"only beforeTool may set \['decision', 'reason'\]",
            id="deny",
        ),
        pytest.param(
            '{"updatedInput": {}}',
            r"only beforeTool may set \['updatedInput'\]",
            id="rewrite",
        ),
        pytest.param(
            '{"decision": "allow", "context": "c"}',
            r"only beforeTool may set \['decision'\]",
            id="allow",
        ),
        pytest.param('{"contexts": "c"}', "unknown field", id="misspelled field"),
        pytest.param('{"context": 1}', "not a string", id="context not a string"),
    ],
)
def test_a_note_carrying_a_verdict_is_an_error(printed: str, error: str) -> None:
    with pytest.raises(ValueError, match=error):
        _ = parse_note(printed)


# The folds.


@given(verdicts)
def test_allow_is_the_identity(verdict: Verdict) -> None:
    assert combine_verdicts(Allow(), verdict) == verdict
    assert combine_verdicts(verdict, Allow()) == verdict


@given(verdicts, verdicts, verdicts)
def test_combining_verdicts_is_associative(a: Verdict, b: Verdict, c: Verdict) -> None:
    assert combine_verdicts(combine_verdicts(a, b), c) == combine_verdicts(
        a, combine_verdicts(b, c)
    )


@given(verdicts, st.builds(Deny, texts.filter(str.strip), contexts))
def test_a_deny_wins_on_either_side(verdict: Verdict, deny: Deny) -> None:
    assert isinstance(combine_verdicts(verdict, deny), Deny)
    assert isinstance(combine_verdicts(deny, verdict), Deny)


def test_contexts_and_reasons_join_in_order() -> None:
    assert combine_verdicts(Allow("one"), Deny("no", "two")) == Deny("no", "one\n\ntwo")
    assert combine_verdicts(Deny("no"), Deny("never")) == Deny("no\nnever")


def test_the_later_rewrite_wins() -> None:
    assert combine_verdicts(Allow(updated_input={"a": 1}), Allow()) == Allow(
        updated_input={"a": 1}
    )
    assert combine_verdicts(
        Allow(updated_input={"a": 1}), Allow(updated_input={"b": 2})
    ) == Allow(updated_input={"b": 2})


@given(notes)
def test_an_empty_note_is_the_identity(note: Note) -> None:
    assert combine_notes(Note(), note) == note
    assert combine_notes(note, Note()) == note


@given(notes, notes, notes)
def test_combining_notes_is_associative(a: Note, b: Note, c: Note) -> None:
    assert combine_notes(combine_notes(a, b), c) == combine_notes(
        a, combine_notes(b, c)
    )


# The dispatcher, with hooks as functions of the event they see.


def test_hooks_run_in_order_each_seeing_the_input_the_one_before_rewrote() -> None:
    def run(hook: Hook, event: BeforeTool) -> Verdict:
        prompt = f"{event.input['prompt']} +{hook.name}"
        return Allow(context=prompt, updated_input={"prompt": prompt})

    result = dispatch_verdict([hook("a"), hook("b")], SPAWN, run)

    assert result == Allow("brief +a\n\nbrief +a +b", {"prompt": "brief +a +b"})


def test_only_hooks_naming_the_tool_run() -> None:
    hooks = [
        hook("shell", frozenset({Tool.SHELL})),
        hook("spawn", frozenset({Tool.DELEGATE, Tool.HANDBACK})),
        hook("every"),
    ]

    result = dispatch_verdict(hooks, SPAWN, lambda hook, _: Allow(hook.name))

    assert result == Allow("spawn\n\nevery")


@pytest.mark.parametrize("event", [START, STARTED, TYPED, STOPPED], ids=event_name)
def test_every_hook_runs_at_an_event_with_no_tool(event: Observed) -> None:
    result = dispatch_note(
        [hook("a"), hook("b")], event, lambda hook, _: Note(hook.name)
    )

    assert result == Note("a\n\nb")


def test_only_hooks_naming_the_tool_add_to_an_after_tool_note() -> None:
    hooks = [
        hook("spawn", frozenset({Tool.DELEGATE})),
        hook("shell", frozenset({Tool.SHELL})),
    ]

    result = dispatch_note(hooks, RAN, lambda hook, _: Note(hook.name))

    assert result == Note("shell")


def test_a_tool_with_no_vendor_free_name_reaches_only_hooks_naming_no_tools() -> None:
    hooks = [hook("shell", frozenset({Tool.SHELL})), hook("every")]

    result = dispatch_note(
        hooks, replace(RAN, tool=Tool.OTHER), lambda hook, _: Note(hook.name)
    )

    assert result == Note("every")


def test_every_hook_runs_past_a_deny_and_every_reason_is_told() -> None:
    def run(hook: Hook, _: BeforeTool) -> Verdict:
        return Deny(hook.name) if hook.name.startswith("guard") else Allow(hook.name)

    hooks = [hook("a"), hook("guard-1"), hook("b"), hook("guard-2")]
    result = dispatch_verdict(hooks, SPAWN, run)

    assert result == Deny("guard-1\nguard-2", "a\n\nb")


def test_a_hook_after_a_deny_sees_the_input_the_allowing_hooks_rewrote() -> None:
    def run(hook: Hook, event: BeforeTool) -> Verdict:
        match hook.name:
            case "rewrite":
                return Allow(updated_input={"prompt": "rewritten"})
            case "guard":
                return Deny("no")
            case _:
                return Allow(context=str(event.input["prompt"]))

    hooks = [hook("rewrite"), hook("guard"), hook("after")]
    result = dispatch_verdict(hooks, SPAWN, run)

    assert result == Deny("no", "rewritten")


def test_no_hooks_allow() -> None:
    assert dispatch_verdict([], SPAWN, lambda _, __: Deny("unreachable")) == Allow()


def test_an_events_hooks_come_from_the_manifest_in_order() -> None:
    manifest = parse_manifest(
        json.dumps(
            {
                "sessionStart": [
                    {"name": "resume", "tools": None, "command": ["resume", "--now"]}
                ],
                "beforeTool": [
                    {"name": "b", "tools": ["delegate"], "command": ["b"]},
                    {"name": "a", "tools": None, "command": ["a"]},
                ],
                "afterTool": [],
                "agentStart": [{"name": "begin", "tools": None, "command": ["b"]}],
            }
        )
    )

    assert hooks_for(manifest, START) == (
        Hook(HookName("resume"), EveryTool(), ("resume", "--now")),
    )
    assert [h.name for h in hooks_for(manifest, SPAWN)] == ["b", "a"]
    assert hooks_for(manifest, RAN) == ()
    assert [h.name for h in hooks_for(manifest, STARTED)] == ["begin"]
    assert hooks_for(manifest, TYPED) == ()


@pytest.mark.parametrize(
    "manifest",
    [
        pytest.param('{"beforeLunch": []}', id="unknown event"),
        pytest.param(
            '{"beforeTool": [{"name": "a", "tools": ["teleport"], "command": ["a"]}]}',
            id="unknown tool",
        ),
        pytest.param(
            '{"beforeTool": [{"name": "a", "tools": null, "command": []}]}',
            id="no command",
        ),
    ],
)
def test_a_manifest_outside_the_contract_is_an_error(manifest: str) -> None:
    with pytest.raises(ValueError):
        _ = parse_manifest(manifest)


# Real hooks, spawned.

ECHO_PROMPT = """
import json, sys
event = json.load(sys.stdin)
print(json.dumps({"updatedInput": {"prompt": event["input"]["prompt"] + " +diff"}}))
"""


def test_a_hook_reads_the_event_and_its_result_counts() -> None:
    assert run_verdict_hook(python("diff", ECHO_PROMPT), SPAWN) == Allow(
        updated_input={"prompt": "brief +diff"}
    )


@pytest.mark.parametrize(
    ("code", "told"),
    [
        pytest.param(
            "import sys; sys.exit('state: no run')",
            "hook broken: exit 1: state: no run",
            id="crash",
        ),
        pytest.param("print('not json')", "hook broken: bad output: ", id="bad output"),
        pytest.param(
            'print(\'{"decision": "deny"}\')',
            "hook broken: bad output: a deny needs a reason",
            id="output outside the contract",
        ),
    ],
)
def test_a_failing_hook_allows_and_tells(code: str, told: str) -> None:
    result = run_verdict_hook(python("broken", code), SPAWN)

    match result:
        case Allow(context=str(context), updated_input=None):
            assert context.startswith(told)
        case _:
            raise AssertionError(result)


def test_a_missing_hook_program_allows_and_tells() -> None:
    result = run_verdict_hook(
        Hook(HookName("gone"), EveryTool(), ("/nonexistent/hook",)), SPAWN
    )

    match result:
        case Allow(context=str(context)):
            assert context.startswith("hook gone: ")
        case _:
            raise AssertionError(result)


def test_the_chain_goes_on_past_a_failing_hook() -> None:
    hooks = [python("broken", "raise SystemExit(3)"), python("diff", ECHO_PROMPT)]

    result = dispatch_verdict(hooks, SPAWN, run_verdict_hook)

    assert result == Allow("hook broken: exit 3: ", {"prompt": "brief +diff"})


@pytest.mark.parametrize("event", [RAN, START])
@pytest.mark.parametrize(
    "printed",
    [
        pytest.param('{"decision": "deny", "reason": "no"}', id="deny"),
        pytest.param('{"updatedInput": {"command": "rm -rf /"}}', id="rewrite"),
    ],
)
def test_a_hook_denying_or_rewriting_after_the_fact_is_told_not_honoured(
    event: SessionStart | AfterTool, printed: str
) -> None:
    result = run_note_hook(python("late", f"print({printed!r})"), event)

    assert result.context is not None
    assert result.context.startswith("hook late: bad output: only beforeTool may set")
