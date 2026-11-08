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
    Result,
    Role,
    SessionId,
    SessionStart,
    Source,
    Tool,
    combine,
    dispatch,
    emit_event,
    emit_result,
    hooks_for,
    parse_event,
    parse_manifest,
    parse_result,
    run_hook,
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
results: st.SearchStrategy[Result] = st.one_of(
    st.builds(Allow, contexts, st.none() | json_objects),
    st.builds(Deny, texts.filter(str.strip), contexts),
)


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


@given(st.sampled_from([SPAWN]), results)
def test_an_emitted_before_tool_result_parses_back_to_itself(
    event: Event, result: Result
) -> None:
    assert parse_result(event, emit_result(result)) == result


@pytest.mark.parametrize("printed", ["", "  \n"])
def test_printing_nothing_allows(printed: str) -> None:
    assert parse_result(SPAWN, printed) == Allow()


@pytest.mark.parametrize(
    ("event", "printed", "error"),
    [
        pytest.param(
            RAN,
            '{"decision": "deny", "reason": "no"}',
            "only beforeTool may deny",
            id="deny after the tool",
        ),
        pytest.param(
            START,
            '{"decision": "deny", "reason": "no"}',
            "only beforeTool may deny",
            id="deny at start",
        ),
        pytest.param(
            RAN,
            '{"updatedInput": {}}',
            "only beforeTool may rewrite",
            id="rewrite after the tool",
        ),
        pytest.param(
            SPAWN, '{"decision": "deny"}', "needs a reason", id="deny without a reason"
        ),
        pytest.param(
            SPAWN,
            '{"decision": "deny", "reason": "no", "updatedInput": {}}',
            "rewrites no input",
            id="deny rewriting",
        ),
        pytest.param(
            SPAWN,
            '{"reason": "why"}',
            "only a deny has a reason",
            id="allow with a reason",
        ),
        pytest.param(
            SPAWN, '{"decision": "maybe"}', "unknown decision", id="unknown decision"
        ),
        pytest.param(
            SPAWN, '{"updated_input": {}}', "unknown field", id="misspelled field"
        ),
        pytest.param(
            SPAWN, '{"updatedInput": "x"}', "not an object", id="input not an object"
        ),
        pytest.param(
            SPAWN, '{"context": 1}', "not a string", id="context not a string"
        ),
        pytest.param(SPAWN, "[]", "not a JSON object", id="not an object"),
    ],
)
def test_a_result_the_event_cannot_honour_is_an_error(
    event: Event, printed: str, error: str
) -> None:
    with pytest.raises(ValueError, match=error):
        _ = parse_result(event, printed)


# The fold.


@given(results)
def test_allow_is_the_identity(result: Result) -> None:
    assert combine(Allow(), result) == result
    assert combine(result, Allow()) == result


@given(results, results, results)
def test_combining_is_associative(a: Result, b: Result, c: Result) -> None:
    assert combine(combine(a, b), c) == combine(a, combine(b, c))


@given(results, st.builds(Deny, texts.filter(str.strip), contexts))
def test_a_deny_wins_on_either_side(result: Result, deny: Deny) -> None:
    assert isinstance(combine(result, deny), Deny)
    assert isinstance(combine(deny, result), Deny)


def test_contexts_and_reasons_join_in_order() -> None:
    assert combine(Allow("one"), Deny("no", "two")) == Deny("no", "one\n\ntwo")
    assert combine(Deny("no"), Deny("never")) == Deny("no\nnever")


def test_the_later_rewrite_wins() -> None:
    assert combine(Allow(updated_input={"a": 1}), Allow()) == Allow(
        updated_input={"a": 1}
    )
    assert combine(
        Allow(updated_input={"a": 1}), Allow(updated_input={"b": 2})
    ) == Allow(updated_input={"b": 2})


# The dispatcher, with hooks as functions of the event they see.


def test_hooks_run_in_order_each_seeing_the_input_the_one_before_rewrote() -> None:
    def run(hook: Hook, event: Event) -> Result:
        assert isinstance(event, BeforeTool)
        prompt = f"{event.input['prompt']} +{hook.name}"
        return Allow(context=prompt, updated_input={"prompt": prompt})

    result = dispatch([hook("a"), hook("b")], SPAWN, run)

    assert result == Allow("brief +a\n\nbrief +a +b", {"prompt": "brief +a +b"})


def test_only_hooks_naming_the_tool_run() -> None:
    hooks = [
        hook("shell", frozenset({Tool.SHELL})),
        hook("spawn", frozenset({Tool.DELEGATE, Tool.HANDBACK})),
        hook("every"),
    ]

    result = dispatch(hooks, SPAWN, lambda hook, _: Allow(hook.name))

    assert result == Allow("spawn\n\nevery")


def test_every_hook_runs_at_session_start() -> None:
    result = dispatch([hook("a"), hook("b")], START, lambda hook, _: Allow(hook.name))

    assert result == Allow("a\n\nb")


def test_the_first_deny_stops_the_chain() -> None:
    def run(hook: Hook, _: Event) -> Result:
        return Deny(hook.name) if hook.name == "guard" else Allow(hook.name)

    result = dispatch([hook("a"), hook("guard"), hook("after")], SPAWN, run)

    assert result == Deny("guard", "a")


def test_no_hooks_allow() -> None:
    assert dispatch([], SPAWN, lambda _, __: Deny("unreachable")) == Allow()


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
    assert run_hook(python("diff", ECHO_PROMPT), SPAWN) == Allow(
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
    result = run_hook(python("broken", code), SPAWN)

    match result:
        case Allow(context=str(context), updated_input=None):
            assert context.startswith(told)
        case _:
            raise AssertionError(result)


def test_a_missing_hook_program_allows_and_tells() -> None:
    result = run_hook(
        Hook(HookName("gone"), EveryTool(), ("/nonexistent/hook",)), SPAWN
    )

    match result:
        case Allow(context=str(context)):
            assert context.startswith("hook gone: ")
        case _:
            raise AssertionError(result)


def test_the_chain_goes_on_past_a_failing_hook() -> None:
    hooks = [python("broken", "raise SystemExit(3)"), python("diff", ECHO_PROMPT)]

    result = dispatch(hooks, SPAWN, run_hook)

    assert result == Allow("hook broken: exit 3: ", {"prompt": "brief +diff"})
