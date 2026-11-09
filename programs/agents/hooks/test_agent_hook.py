"""The neutral hook contract and its dispatcher: events and results survive the
wire, results fold as a monoid, and a hook that fails never blocks a call."""

import json
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
    Event,
    EventName,
    EveryTool,
    Hook,
    HookName,
    Json,
    Note,
    Role,
    SessionId,
    SessionStart,
    Source,
    Tool,
    Verdict,
    combine_notes,
    combine_verdicts,
    dispatch_note,
    dispatch_verdict,
    emit_event,
    emit_result,
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

VOCABULARY = Path(__file__).with_name("vocabulary.json")

SESSION = SessionId("s1")
CWD = Path("/work/repo")
WORKER = Agent(AgentId("a1"), Role("implementer"))
START = SessionStart(SESSION, CWD, None, Source.RESUME)
SPAWN = BeforeTool(SESSION, CWD, None, Tool.DELEGATE, {"prompt": "brief"})
RAN = AfterTool(SESSION, CWD, WORKER, Tool.SHELL, {"command": "ls"}, "a\nb\n")

json_values = st.recursive(
    st.none() | st.booleans() | st.integers() | st.text(),
    lambda children: (
        st.lists(children, max_size=3)
        | st.dictionaries(st.text(), children, max_size=3)
    ),
    max_leaves=8,
)
json_objects = st.dictionaries(st.text(), json_values, max_size=3)
texts = st.text(min_size=1)
agents = st.none() | st.builds(Agent, st.text().map(AgentId), st.text().map(Role))
paths = st.text(alphabet="abc/", min_size=1).map(lambda p: Path("/" + p))
sessions = st.text().map(SessionId)
events: st.SearchStrategy[Event] = st.one_of(
    st.builds(SessionStart, sessions, paths, agents, st.sampled_from(Source)),
    st.builds(BeforeTool, sessions, paths, agents, st.sampled_from(Tool), json_objects),
    st.builds(
        AfterTool,
        sessions,
        paths,
        agents,
        st.sampled_from(Tool),
        json_objects,
        json_values,
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


@pytest.mark.parametrize(
    "wire",
    [
        pytest.param(
            {"event": "beforeLunch", "session": "s", "cwd": "/", "agent": None},
            id="unknown event",
        ),
        pytest.param(
            {
                "event": "beforeTool",
                "session": "s",
                "cwd": "/",
                "agent": None,
                "tool": "teleport",
                "input": {},
            },
            id="unknown tool",
        ),
        pytest.param(
            {
                "event": "sessionStart",
                "session": "s",
                "cwd": "/",
                "agent": None,
                "source": "clear",
            },
            id="unknown source",
        ),
        pytest.param(
            {
                "event": "beforeTool",
                "session": "s",
                "cwd": "/",
                "agent": {"id": "a"},
                "tool": "shell",
                "input": {},
            },
            id="agent without a role",
        ),
    ],
)
def test_an_event_outside_the_contract_is_an_error(wire: Json) -> None:
    with pytest.raises(ValueError):
        _ = parse_event(json.dumps(wire))


def test_an_event_reads_as_the_wire_names_it() -> None:
    wire = {
        "event": "afterTool",
        "tool": "shell",
        "input": {"command": "ls"},
        "output": "a\nb\n",
        "cwd": "/work/repo",
        "session": "s1",
        "agent": {"id": "a1", "role": "implementer"},
    }

    assert parse_event(json.dumps(wire)) == RAN


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


def test_every_hook_runs_at_session_start() -> None:
    result = dispatch_note(
        [hook("a"), hook("b")], START, lambda hook, _: Note(hook.name)
    )

    assert result == Note("a\n\nb")


def test_only_hooks_naming_the_tool_add_to_an_after_tool_note() -> None:
    hooks = [
        hook("spawn", frozenset({Tool.DELEGATE})),
        hook("shell", frozenset({Tool.SHELL})),
    ]

    result = dispatch_note(hooks, RAN, lambda hook, _: Note(hook.name))

    assert result == Note("shell")


def test_the_first_deny_stops_the_chain() -> None:
    def run(hook: Hook, _: BeforeTool) -> Verdict:
        return Deny(hook.name) if hook.name == "guard" else Allow(hook.name)

    result = dispatch_verdict([hook("a"), hook("guard"), hook("after")], SPAWN, run)

    assert result == Deny("guard", "a")


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
            }
        )
    )

    assert hooks_for(manifest, START) == (
        Hook(HookName("resume"), EveryTool(), ("resume", "--now")),
    )
    assert [h.name for h in hooks_for(manifest, SPAWN)] == ["b", "a"]
    assert hooks_for(manifest, RAN) == ()


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
