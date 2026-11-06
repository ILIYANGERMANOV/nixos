"""`state`: the issue's laws as properties over generated event lists, the
transition table row by row, the hand-back parser on real first lines, and the
command line on temp git repos, as test_ctx.py does."""

import io
import json
import subprocess
import tempfile
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st
from state import (
    AREAS,
    BLOCKER_KINDS,
    MODES,
    OUTCOMES,
    PROPOSAL_MODES,
    ROLES,
    S0,
    STATES,
    Adjusted,
    Advice,
    Asked,
    Blocked,
    Ci,
    Confirmed,
    Defaulted,
    Drafted,
    Event,
    Facts,
    Failure,
    Fixed,
    GitFacts,
    Grew,
    HandbackOptions,
    Implemented,
    Line,
    NoFacts,
    Overridden,
    Planned,
    Proposed,
    Quality,
    Ready,
    Refactored,
    Researched,
    Resolved,
    Reviewed,
    Size,
    Started,
    State,
    Verdict,
    advise,
    apply,
    encode_line,
    fold,
    main,
    parse_handback,
    parse_log,
    render,
    render_advice,
    replay,
    show,
)

ROOT = Path(__file__).resolve().parents[3]
SKILL = ROOT / "programs/agents/skills/custom/engineer/SKILL.md"
BLOCKERS = ROOT / "programs/agents/skills/custom/engineer/references/blockers.md"
QUALITY_MD = ROOT / "programs/agents/instructions/topics/quality.md"
NOTES = "/notes/run"
NO_FACTS = NoFacts()
LOG = Path("/notes/run/events.jsonl")
TOKENS = ("SPAWN ", "ASK ", "WAIT ", "RUN ", "STUCK ", "DONE")

# ---- Builders -------------------------------------------------------------------


def reach(*events: Event) -> State:
    match fold(events):
        case State() as state:
            return state
        case Failure() as failure:
            raise AssertionError(failure.message)


def drafted(
    quality: str = "Balanced", size: str = "Normal", *, delegated: bool = False
) -> list[Event]:
    """A run up to Impl: the plan confirmed and the draft PR 7 against main."""
    started = Started(NOTES, delegated=delegated)
    knobs = [Size(size), Quality(quality)]  # pyright: ignore[reportArgumentType]
    if delegated:
        return [started, *knobs, Drafted(7, "main")]
    return [
        started,
        knobs[0],
        Planned(f"{NOTES}/plan.md"),
        knobs[1],
        *(Proposed(m) for m in PROPOSAL_MODES),
        Confirmed(),
        Drafted(7, "main"),
    ]


def reviewed(quality: str = "Balanced", size: str = "Normal") -> list[Event]:
    """Implemented, refactored, then a first review that chose rows R1 and R2."""
    return [
        *drafted(quality, size),
        Implemented("h1"),
        Refactored("h2"),
        Reviewed("h3", ("R1", "R2"), ()),
    ]


def final_fixed(quality: str = "Balanced", *, delegated: bool = False) -> list[Event]:
    """A run in DraftPR: a first review with no rows, then the final fixer."""
    return [
        *drafted(quality, delegated=delegated),
        Implemented("h1"),
        Refactored("h2"),
        Reviewed("h3", (), ()),
        Fixed("h4", ()),
    ]


def advice(*events: Event, facts: Facts = NO_FACTS) -> str:
    return render_advice(advise(reach(*events), facts))


def first_line(text: str) -> str:
    return text.splitlines()[0]


# ---- Generators -----------------------------------------------------------------

# Small alphabets, so heads, rows and questions repeat and the guards see it.
heads = st.sampled_from(["a1", "b2", "c3"])
labels = st.sampled_from(["R1", "R2", "R3"])
questions = st.sampled_from(["q1", "q2"])

events: st.SearchStrategy[Event] = st.one_of(
    st.builds(Started, st.just(NOTES), st.booleans()),
    st.builds(Quality, st.sampled_from(MODES)),
    st.builds(Size, st.sampled_from(("Trivial", "Normal"))),
    st.builds(Grew, st.just("bigger")),
    st.builds(Defaulted, st.sampled_from(("quality", "size"))),
    st.builds(Researched, st.integers(1, 3)),
    st.builds(Asked, st.integers(1, 3)),
    st.builds(Planned, st.just(f"{NOTES}/plan.md")),
    st.builds(Proposed, st.sampled_from(PROPOSAL_MODES)),
    st.builds(Confirmed),
    st.builds(Adjusted),
    st.builds(Drafted, st.integers(1, 9), st.just("main")),
    st.builds(Implemented, heads),
    st.builds(Refactored, heads),
    st.builds(
        Reviewed,
        heads,
        st.lists(labels, max_size=2).map(tuple),
        st.lists(
            st.builds(
                Verdict, st.sampled_from(["AC1", "AC2"]), st.sampled_from(OUTCOMES)
            ),
            max_size=2,
        ).map(tuple),
    ),
    st.builds(Fixed, heads, st.lists(st.sampled_from(AREAS), max_size=2).map(tuple)),
    st.builds(
        Ci, heads, st.lists(st.sampled_from(["lint", "test"]), max_size=2).map(tuple)
    ),
    st.builds(
        Blocked, questions, st.sampled_from(BLOCKER_KINDS), st.sampled_from(ROLES)
    ),
    st.builds(Resolved, questions, st.just("yes")),
    st.builds(Overridden, st.sampled_from(STATES), st.just("why")),
    st.builds(Ready, st.integers(1, 9)),
)
event_lists = st.lists(events, max_size=40)
facts: st.SearchStrategy[Facts] = st.one_of(
    st.just(NoFacts()),
    st.builds(
        GitFacts, st.integers(0, 300), st.sampled_from(["none", "changed", "new"])
    ),
)


def walk(candidates: list[Event]) -> list[tuple[State, Event, State]]:
    """Each accepted arrow of a run that offers `candidates` in order and keeps
    only the events the flow accepts, as a lead that reads the error would."""
    steps: list[tuple[State, Event, State]] = []
    state = S0
    for event in candidates:
        match apply(state, event):
            case State() as after:
                steps.append((state, event, after))
                state = after
            case Failure():
                pass
    return steps


def accepted(candidates: list[Event]) -> list[Event]:
    return [event for _, event, _ in walk(candidates)]


# ---- Laws -----------------------------------------------------------------------


def test_fold_of_nothing_is_the_initial_state() -> None:
    assert fold([]) == S0


@given(event_lists, event_lists)
def test_replay_fold_of_a_concatenation_continues_from_the_fold_of_its_head(
    head: list[Event], tail: list[Event]
) -> None:
    prefix = accepted(head)

    middle = reach(*prefix)

    match fold([*prefix, *tail]), fold(tail, middle):
        case Failure(fix=whole), Failure(fix=rest):
            assert whole == rest  # the message numbers the event from its fold's start
        case whole, rest:
            assert whole == rest


@given(event_lists)
def test_replay_the_written_log_replays_to_the_fold_of_its_events(
    candidates: list[Event],
) -> None:
    run = accepted(candidates)
    text = "".join(
        encode_line(Line(n, "t", None, None, event))
        for n, event in enumerate(run, start=1)
    )

    match parse_log(text, LOG):
        case Failure() as failure:
            raise AssertionError(failure.message)
        case lines:
            assert replay(lines, LOG) == fold(run)


@given(event_lists, events)
def test_total_apply_is_defined_on_every_state_and_event(
    candidates: list[Event], event: Event
) -> None:
    state = reach(*accepted(candidates))

    after = apply(state, event)

    assert isinstance(after, State | Failure)


@given(event_lists, facts)
def test_advisory_next_always_advises_an_arrow(
    candidates: list[Event], git: Facts
) -> None:
    advised: Advice = advise(reach(*accepted(candidates)), git)

    assert first_line(render_advice(advised)).startswith(TOKENS)


@given(event_lists)
def test_monotone_knobs_quality_is_set_once_and_size_only_grows(
    candidates: list[Event],
) -> None:
    for before, _, after in walk(candidates):
        assert before.quality in (None, after.quality)
        assert (before.size, after.size) != ("Normal", "Trivial")
        assert before.size is None or after.size is not None


@given(event_lists, st.sampled_from(STATES))
def test_fixed_targets_an_override_lands_on_its_target_from_any_state(
    candidates: list[Event], to: str
) -> None:
    state = reach(*accepted(candidates))

    after = apply(state, Overridden(to, "why"))  # pyright: ignore[reportArgumentType]

    assert isinstance(after, State)
    assert after.step == to


@given(event_lists)
def test_fixed_targets_knobs_counts_and_triage_never_move_the_step(
    candidates: list[Event],
) -> None:
    for before, event, after in walk(candidates):
        match event:
            case (
                Quality() | Size() | Grew() | Defaulted() | Researched() | Resolved()
                | Blocked(kind="answered" | "fact" | "scope")
            ):  # fmt: skip
                assert after.step == before.step
            case Blocked(kind="decision"):
                assert after.step == "Ctx"
            case _:
                pass


@given(heads, heads, labels, st.lists(labels, max_size=2))
def test_stuck_guard_the_same_row_in_two_rounds_in_a_row_is_stuck(
    first: str, second: str, row: str, others: list[str]
) -> None:
    text = advice(
        *drafted("Max"),
        Implemented("h1"),
        Refactored("h2"),
        Reviewed(first, (row,), ()),
        Fixed("h4", ()),
        Reviewed(second, (*others, row), ()),
    )

    assert first_line(text) == f"STUCK row {row} in 2 rounds in a row"


@given(heads, heads)
def test_stuck_guard_the_same_failing_check_twice_is_stuck(
    first: str, second: str
) -> None:
    text = advice(
        *reviewed("POC"),
        Fixed("h4", ()),
        Reviewed("h5", (), ()),
        Fixed("h6", ()),
        Ci(first, ("lint",)),
        Fixed("h7", ()),
        Ci(second, ("lint", "test")),
    )

    assert first_line(text) == "STUCK check lint failing in 2 rounds in a row"


def test_stuck_guard_different_rows_in_two_rounds_are_not_stuck() -> None:
    text = advice(
        *drafted("Max"),
        Implemented("h1"),
        Refactored("h2"),
        Reviewed("h3", ("R1",), ()),
        Fixed("h4", ()),
        Reviewed("h5", ("R2",), ()),
    )

    assert first_line(text) == "SPAWN fixer"


def test_stuck_guard_the_same_question_back_after_it_closed_is_stuck() -> None:
    text = advice(
        *drafted(),
        Blocked("which log?", "answered", "implementer"),
        Resolved("which log?", "the notes dir"),
        Blocked("which log?", "answered", "implementer"),
    )

    assert first_line(text) == "STUCK question 'which log?' back in 2 rounds in a row"


def test_stuck_guard_delegated_hands_the_stuck_back() -> None:
    text = advice(
        *drafted("Max", delegated=True),
        Implemented("h1"),
        Refactored("h2"),
        Reviewed("h3", ("R1",), ()),
        Fixed("h4", ()),
        Reviewed("h5", ("R1",), ()),
    )

    assert text.splitlines()[1] == (
        "  hand back: NEEDS_DECISION stuck: row R1 in 2 rounds in a row, the work pushed"
    )


# ---- Prose guard ------------------------------------------------------------------


def states_block(skill: str) -> str:
    """`## States` up to the next `## ` heading, its trailing blank line dropped."""
    start = skill.index("## States\n")
    end = skill.index("\n## ", start)
    return skill[start:end]


def test_prose_guard_the_skills_states_block_is_state_render() -> None:
    block = states_block(SKILL.read_text())

    assert render().startswith(block + "\n"), (
        f"paste `state render`'s States block into {SKILL}:\n\n{render()}"
    )


def test_prose_guard_the_engineers_quality_rows_are_lines_of_quality_md_in_order() -> (
    None
):
    rows = render()[len(states_block(SKILL.read_text())) + 1 :].splitlines()
    lines = QUALITY_MD.read_text().splitlines()

    found = [lines.index(row) if row in lines else -1 for row in rows]

    assert -1 not in found, f"paste these rows into {QUALITY_MD}:\n\n" + "\n".join(rows)
    assert found == sorted(found)


def stop_rule_of(blockers: str) -> str:
    """The quoted paragraph under `## The stop rule`."""
    section = blockers.split("## The stop rule\n", 1)[1]
    quoted = section.split("\n\n")[1]
    assert quoted.startswith("> ")
    return quoted


# ---- The table, row by row ----------------------------------------------------------


@pytest.mark.parametrize(
    ("run", "git", "line1", "payload"),
    [
        pytest.param(
            [Started(NOTES, delegated=False)], NoFacts(),
            "RUN state record size Trivial|Normal", "before step 1",
            id="Ctx: no Size yet",
        ),
        pytest.param(
            [Started(NOTES, delegated=False), Size("Normal")], NoFacts(),
            f"RUN state record planned {NOTES}/plan.md",
            "researchers 0 (at least 1, typically 2-3; Balanced: up to 3, 15 calls, notes)",
            id="Ctx: research and ask, then the plan",
        ),
        pytest.param(
            [Started(NOTES, delegated=False), Size("Trivial")], NoFacts(),
            f"RUN state record planned {NOTES}/plan.md",
            "researchers 0 (Trivial: none, at most 5 lookups by you)",
            id="Ctx: Trivial researches nothing",
        ),
        pytest.param(
            [Started(NOTES, delegated=False), Size("Normal"), Planned("p.md")], NoFacts(),
            "ASK quality", "POC, Balanced (Recommended), Max",
            id="Prop: Quality asked once",
        ),
        pytest.param(
            [Started(NOTES, delegated=False), Size("Normal"), Planned("p.md"), Quality("Balanced")],
            NoFacts(), "SPAWN researcher", "modes: simplify, alternative  Quality: Balanced",
            id="Prop: Balanced proposals",
        ),
        pytest.param(
            [Started(NOTES, delegated=False), Size("Normal"), Planned("p.md"), Quality("POC")],
            NoFacts(), "SPAWN researcher", "modes: simplify  Quality: POC",
            id="Prop: POC simplifies only",
        ),
        pytest.param(
            [
                Started(NOTES, delegated=False), Size("Normal"), Planned("p.md"), Quality("Max"),
                Proposed("simplify"), Proposed("alternative"),
            ],
            NoFacts(), "ASK plan", '"First plan", "Second plan", "Adjust"',
            id="Prop: proposals back, ask the plan",
        ),
        pytest.param(
            [Started(NOTES, delegated=False), Size("Trivial"), Planned("p.md")], NoFacts(),
            "RUN state record confirmed", "Trivial: no proposals",
            id="Prop: Trivial confirms itself",
        ),
        pytest.param(
            drafted()[:-1], NoFacts(), "RUN gh pr create --draft",
            "body: the plan, Quality: Balanced  Size: Normal, acceptance criteria,",
            id="DraftPlan: the draft PR",
        ),
        pytest.param(
            drafted("POC")[:-1], NoFacts(), "RUN gh pr create --draft",
            "POC: gh label create POC --force", id="DraftPlan: POC labels it",
        ),
        pytest.param(
            [Started(NOTES, delegated=True), Size("Normal")], NoFacts(),
            "RUN state record quality <your brief's Quality: line>",
            "delegated: the brief sets both knobs", id="DraftPlan: delegated knobs",
        ),
        pytest.param(
            [Started(NOTES, delegated=True), Size("Normal"), Quality("Max")], NoFacts(),
            "RUN gh pr create --draft --repo <repo> --head <branch> --base <base>",
            "the worktree exists: no branching; no attach", id="DraftPlan: delegated draft",
        ),
        pytest.param(
            drafted(), NoFacts(), "SPAWN implementer", "Balanced: as planned",
            id="Impl: implementers",
        ),
        pytest.param(
            drafted("POC"), NoFacts(), "SPAWN implementer",
            "POC: one implementer, one happy-path proof as its test", id="Impl: POC",
        ),
        pytest.param(
            [*drafted("Max"), Implemented("h1")], GitFacts(10, "none"),
            "SPAWN refactorer", "Max: always", id="Impl': Max always refactors",
        ),
        pytest.param(
            [*drafted(), Implemented("h1")], GitFacts(100, "none"), "SPAWN review-lead",
            "refactor skipped: 100 changed lines, Balanced",
            id="Impl': Balanced skips at 100 lines",
        ),
        pytest.param(
            [*drafted(), Implemented("h1")], GitFacts(101, "none"), "SPAWN refactorer",
            "Balanced: above about 100 changed lines", id="Impl': Balanced above 100",
        ),
        pytest.param(
            [*drafted("POC"), Implemented("h1")], GitFacts(5, "none"), "SPAWN refactorer",
            "POC: quick: items 1-3, no `tests.md`", id="Impl': POC refactors quick",
        ),
        pytest.param(
            [*drafted("Max", "Trivial"), Implemented("h1")], GitFacts(500, "none"),
            "SPAWN review-lead", "refactor skipped: Trivial", id="Impl': Trivial skips",
        ),
        pytest.param(
            [*drafted(), Implemented("h1"), Refactored("h2")], GitFacts(5, "none"),
            "SPAWN review-lead",
            ("invoke `pragmatic-review` with: Quality: Balanced Size: Normal "
            f"--requirements {NOTES}/requirements.md 7"),
            id="ImplR: the first review",
        ),
        pytest.param(
            [*drafted(), Implemented("h1"), Refactored("h2")], GitFacts(5, "new"),
            "SPAWN review-lead", "also: SPAWN reviewer",
            id="ImplR: Balanced dry-runs a new skill",
        ),
        pytest.param(
            [*drafted(), Implemented("h1"), Refactored("h2")], GitFacts(5, "changed"),
            "SPAWN review-lead", "a dry run only if it is rewritten",
            id="ImplR: Balanced asks whether a changed skill is rewritten",
        ),
        pytest.param(
            [*drafted("Max"), Implemented("h1"), Refactored("h2")],
            GitFacts(5, "changed"), "SPAWN review-lead", "also: SPAWN reviewer",
            id="ImplR: Max dry-runs any skill change",
        ),
        pytest.param(
            reviewed(), NoFacts(), "SPAWN fixer", "rows: R1, R2",
            id="Impl'': fix the chosen rows",
        ),
        pytest.param(
            [*reviewed(), Fixed("h4", ())], NoFacts(), "SPAWN review-lead",
            ("invoke `pragmatic-review` with: Quality: Balanced Size: Normal --fixes h3 "
            f"--requirements {NOTES}/requirements-fixes.md 7"),
            id="Impl'': a --fixes review of the previous Reviewed head",
        ),
        pytest.param(
            [*reviewed(), Fixed("h4", ("interface",))], NoFacts(), "SPAWN review-lead",
            "--fixes h3", id="Impl'': Balanced keeps --fixes for an interface fix",
        ),
        pytest.param(
            [*reviewed(), Fixed("h4", ("auth",))], NoFacts(), "SPAWN review-lead",
            "a fix to auth: a first review of the whole branch, a round",
            id="Impl'': an auth fix gets a whole-branch review",
        ),
        pytest.param(
            [
                *reviewed(), Fixed("h4", ()), Reviewed("h5", ("R3",), ()),
                Fixed("h6", ()), Reviewed("h7", ("R4",), ()),
            ],
            NoFacts(), "SPAWN fixer", "final fixer: rows R4, R0; nothing reviews it",
            id="Impl'': Balanced's cap of 2 re-reviews goes to the final fixer",
        ),
        pytest.param(
            [*reviewed("POC"), Fixed("h4", ()), Reviewed("h5", ("R3",), ())],
            NoFacts(), "SPAWN fixer", "final fixer: rows R3, R0",
            id="Impl'': POC's cap of 1",
        ),
        pytest.param(
            [
                *reviewed("POC"), Fixed("h4", ()),
                Reviewed("h5", ("R3",), (Verdict("AC1", "not-met"),)),
            ],
            NoFacts(), "SPAWN fixer", "at the cap: fix only Not met AC1",
            id="Impl'': Not met loops even at the cap",
        ),
        pytest.param(
            [*drafted(), Implemented("h1"), Refactored("h2"), Reviewed("h3", (), ())],
            NoFacts(), "SPAWN fixer", "final fixer: rows R0", id="ImplR: no rows",
        ),
        pytest.param(
            [*drafted("Max", "Trivial"), Implemented("h1"), Reviewed("h3", ("R1",), ())],
            NoFacts(), "SPAWN fixer", "final fixer: rows R1, R0",
            id="Impl': Trivial has no re-review",
        ),
        pytest.param(
            final_fixed(), NoFacts(), "WAIT ci", "notify: the draft is complete and CI runs",
            id="DraftPR: notify and wait for CI",
        ),
        pytest.param(
            final_fixed(delegated=True), NoFacts(), "DONE", "hand back: READY 7, the work pushed",
            id="DraftPR: delegated hands back",
        ),
        pytest.param(
            [*final_fixed(), Ci("h4", ())], NoFacts(), "RUN gh pr ready 7", "then: state record ready 7",
            id="PR: green CI, ready",
        ),
        pytest.param(
            [*final_fixed("POC"), Ci("h4", ())], NoFacts(), "DONE", "the PR stays a labelled draft", id="PR: POC stays a draft",
        ),
        pytest.param(
            [*final_fixed(), Ci("h4", ("lint",))], NoFacts(), "SPAWN fixer", "CI fix: lint", id="PR: CI fix",
        ),
        pytest.param(
            [*final_fixed(), Ci("h4", ("lint",)), Fixed("h5", ())],
            NoFacts(), "SPAWN review-lead", "a --fixes review of the CI fix",
            id="PR: a CI fix gets a --fixes review",
        ),
        pytest.param(
            [*final_fixed(), Ci("h4", ()), Ready(7)], NoFacts(), "DONE", "the PR is ready", id="Done",
        ),
        pytest.param(
            [*drafted(), Implemented("h1"), Blocked("which log?", "answered", "implementer")],
            NoFacts(), "SPAWN implementer", "continue from commit `h1`",
            id="blocker: answered resumes a fresh worker",
        ),
        pytest.param(
            [*drafted(), Blocked("git or notes?", "fact", "implementer")],
            NoFacts(), "SPAWN researcher", "one researcher for 'git or notes?'",
            id="blocker: a fact gets a researcher",
        ),
        pytest.param(
            [*drafted(), Blocked("add a hook?", "scope", "fixer")],
            NoFacts(), "ASK scope", "in this PR, a follow-up, or drop",
            id="blocker: scope asks the user",
        ),
        pytest.param(
            [*drafted(delegated=True), Blocked("add a hook?", "scope", "fixer")],
            NoFacts(), "DONE", "hand back: NEEDS_DECISION add a hook?, the work pushed",
            id="blocker: delegated scope hands back",
        ),
        pytest.param(
            [*drafted(), Blocked("plan wrong: no PR", "decision", "review-lead")],
            NoFacts(), f"RUN state record planned {NOTES}/plan.md",
            "decision path for 'plan wrong: no PR'", id="blocker: a decision re-plans in Ctx",
        ),
        pytest.param(
            [*drafted(delegated=True), Blocked("plan wrong: x", "decision", "review-lead")],
            NoFacts(), "DONE", "hand back: NEEDS_DECISION plan wrong: x, the work pushed",
            id="blocker: delegated decision hands back",
        ),
        pytest.param(
            [*drafted(), Blocked("which log?", "fact", "implementer"),
             Resolved("which log?", "notes")],
            NoFacts(), "SPAWN implementer", "brief: state brief implementer, plus its slice",
            id="blocker: resolved, the step's own arrow",
        ),
        pytest.param(
            [*reviewed(), Blocked("plan wrong: x", "decision", "review-lead"),
             Planned("p2.md"), Proposed("simplify"), Proposed("alternative")],
            NoFacts(), "ASK plan", "picked, a re-plan: gh pr edit 7 --body-file",
            id="re-plan: the chosen plan goes into the PR body",
        ),
    ],
)  # fmt: skip
def test_next_advises_the_tables_arrow_with_its_payload(
    run: list[Event], git: Facts, line1: str, payload: str
) -> None:
    text = advice(*run, facts=git)

    assert first_line(text) == line1
    assert payload in text


def test_a_confirmed_re_plan_resumes_at_impl_and_restarts_the_rounds() -> None:
    state = reach(
        *reviewed(),
        Fixed("h4", ()),
        Reviewed("h5", ("R3",), ()),
        Blocked("plan wrong: x", "decision", "review-lead"),
        Planned("p2.md"),
        Proposed("simplify"),
        Proposed("alternative"),
        Confirmed(),
    )

    assert state.step == "Impl"
    assert "Re-review: 0/2" in show(state)


def test_a_re_plan_keeps_the_stuck_history() -> None:
    text = advice(
        *drafted("Max"),
        Implemented("h1"),
        Refactored("h2"),
        Reviewed("h3", ("R1",), ()),
        Blocked("plan wrong: x", "decision", "review-lead"),
        Planned("p2.md"),
        Confirmed(),
        Implemented("h4"),
        Refactored("h5"),
        Reviewed("h6", ("R1",), ()),
    )

    assert first_line(text) == "STUCK row R1 in 2 rounds in a row"


def test_quality_is_set_once() -> None:
    assert isinstance(fold([Quality("POC"), Quality("Max")]), Failure)


def test_size_never_shrinks_to_trivial() -> None:
    assert isinstance(fold([Size("Normal"), Size("Trivial")]), Failure)


def test_a_trivial_task_that_grew_is_normal() -> None:
    assert reach(Size("Trivial"), Grew("a migration")).size == "Normal"


def test_an_event_off_the_table_is_an_error_naming_the_override() -> None:
    match fold([Started(NOTES, delegated=False), Ready(7)]):
        case Failure(message=message, fix=fix, code=code):
            assert (message, code) == ("event 2: 'ready' is not an arrow out of Ctx", 2)
            assert "state override <state> <why>" in fix
        case State():
            raise AssertionError("ready is no arrow out of Ctx")


# ---- Hand-backs -----------------------------------------------------------------------


@pytest.mark.parametrize(
    ("role", "text", "options", "expected"),
    [
        pytest.param(
            "implementer", "READY 0c8fe31 [agents] state: core and shell\n\nProof: ruff",
            HandbackOptions(), (Implemented("abc1234"),), id="implementer READY",
        ),
        pytest.param(
            "refactorer", "READY - items 1-7 done, no proposals", HandbackOptions(),
            (Refactored("abc1234"),), id="refactorer READY",
        ),
        pytest.param(
            "fixer", "READY rows R1, R2 fixed in 5e1f2a9", HandbackOptions(touches=("auth",)),
            (Fixed("abc1234", ("auth",)),), id="fixer READY with what it touched",
        ),
        pytest.param(
            "implementer",
            "NEEDS_DECISION Should the log live in the git dir?\nGREW a second format\n",
            HandbackOptions(kind="fact"),
            (Blocked("Should the log live in the git dir?", "fact", "implementer"),
             Grew("a second format")),
            id="NEEDS_DECISION then GREW on the next line",
        ),
        pytest.param(
            "fixer", "GREW the fix needs a migration", HandbackOptions(),
            (Grew("the fix needs a migration"),), id="GREW",
        ),
        pytest.param(
            "fixer", "BLOCKED nix build fails: no network", HandbackOptions(kind="fact"),
            (Blocked("BLOCKED nix build fails: no network", "fact", "fixer"),),
            id="BLOCKED triaged",
        ),
        pytest.param(
            "implementer", "FAILED the test harness is missing",
            HandbackOptions(kind="scope"),
            (Blocked("FAILED the test harness is missing", "scope", "implementer"),),
            id="FAILED triaged",
        ),
        pytest.param(
            "review-lead",
            ("| # | Severity | What |\n|---|---|---|\n| 1 | Blocker | x |\n\n"
            "Reviewed head: 9f8e7d6\n"),
            HandbackOptions(rows=("R1",), verdicts=(Verdict("AC1", "met"),)),
            (Reviewed("9f8e7d6", ("R1",), (Verdict("AC1", "met"),)),),
            id="review-lead report",
        ),
        pytest.param(
            "review-lead",
            ("NEEDS_DECISION plan wrong: the fold cannot see the PR\n\n| table |\n\n"
            "Reviewed head: 9f8e7d6"),
            HandbackOptions(),
            (Reviewed("9f8e7d6", (), ()),
             Blocked("plan wrong: the fold cannot see the PR", "decision", "review-lead")),
            id="review-lead plan wrong: a decision, its review recorded",
        ),
        pytest.param(
            "fixer", "NEEDS_DECISION stuck: lint in 2 rounds", HandbackOptions(),
            (Blocked("stuck: lint in 2 rounds", "decision", "fixer"),),
            id="a stuck hand-back is a decision",
        ),
    ],
)  # fmt: skip
def test_handback_records_the_event_its_first_line_names(
    role: str, text: str, options: HandbackOptions, expected: tuple[Event, ...]
) -> None:
    assert parse_handback(role, text, options, "abc1234") == expected  # pyright: ignore[reportArgumentType]


@pytest.mark.parametrize(
    ("role", "text", "options", "head", "fix"),
    [
        pytest.param(
            "implementer", "NEEDS_DECISION which log?", HandbackOptions(), "abc1234",
            "add --kind answered|fact|decision|scope (blockers.md, Triage)",
            id="an untriaged question",
        ),
        pytest.param(
            "review-lead", "| table |", HandbackOptions(), "abc1234",
            "state record reviewed <sha> [--row <label>]... by hand",
            id="a review without its Reviewed head",
        ),
        pytest.param(
            "fixer", "Done, all green.", HandbackOptions(), "abc1234",
            "record it by hand: state record fixed ...", id="no status token",
        ),
        pytest.param(
            "implementer", "READY", HandbackOptions(), None,
            "run it in the worktree, or state record implemented <sha>", id="no HEAD",
        ),
    ],
)  # fmt: skip
def test_handback_without_what_it_needs_is_a_usage_error(
    role: str, text: str, options: HandbackOptions, head: str | None, fix: str
) -> None:
    match parse_handback(role, text, options, head):  # pyright: ignore[reportArgumentType]
        case Failure(fix=found, code=code):
            assert (found, code) == (fix, 2)
        case parsed:
            raise AssertionError(f"parsed {parsed}")


# ---- The command line on temp git repos ---------------------------------------------

IDENTITY = ("-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false")


def git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *IDENTITY, *args], cwd=repo, check=True, capture_output=True, text=True
    ).stdout


def commit(repo: Path, files: dict[str, str], message: str) -> str:
    for name, text in files.items():
        path = repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        _ = path.write_text(text)
    _ = git(repo, "add", "--all")
    _ = git(repo, "commit", "--quiet", f"--message={message}")
    return git(repo, "rev-parse", "HEAD").strip()


def make_repo(root: Path) -> Path:
    """main has one commit, which origin/main points at; `feature` is checked out."""
    path = root / "repo"
    path.mkdir()
    _ = git(path, "init", "--quiet", "--initial-branch=main")
    _ = commit(path, {"a.txt": "one\n"}, "base")
    _ = git(path, "update-ref", "refs/remotes/origin/main", "HEAD")
    _ = git(path, "switch", "--quiet", "--create", "feature")
    return path


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    return make_repo(tmp_path)


def run(cwd: Path, *argv: str, stdin: str | None = None) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        code = main(list(argv), cwd, stdin)
    return code, out.getvalue(), err.getvalue()


def ok(cwd: Path, *argv: str, stdin: str | None = None) -> str:
    code, out, err = run(cwd, *argv, stdin=stdin)
    assert (code, err) == (0, ""), err
    return out


def log_of(notes: Path) -> list[dict[str, object]]:
    return [
        json.loads(line) for line in (notes / "events.jsonl").read_text().splitlines()
    ]


def to_impl(repo: Path, notes: Path) -> None:
    """init, then the shortest recorded path to Impl at Balanced, PR 7 on main."""
    for argv in (
        ("init", "--notes", str(notes)),
        ("record", "size", "Normal"),
        ("record", "planned", f"{notes}/plan.md"),
        ("record", "quality", "Balanced"),
        ("record", "confirmed"),
        ("record", "drafted", "7", "main"),
    ):
        _ = ok(repo, *argv)


COMMANDS = st.sampled_from(
    [
        ("init",),
        ("record", "researched"),
        ("record", "asked", "3"),
        ("record", "quality", "POC"),
        ("record", "quality", "Max"),
        ("record", "size", "Normal"),
        ("record", "size", "Trivial"),
        ("record", "grew", "bigger"),
        ("record", "planned", "plan.md"),
        ("record", "confirmed"),
        ("record", "drafted", "7", "main"),
        ("record", "implemented"),
        ("record", "bogus"),
        ("override", "PR", "jump"),
    ]
)


@settings(deadline=None, max_examples=25)
@given(st.lists(COMMANDS, min_size=1, max_size=8))
def test_shell_the_log_is_append_only_with_a_dense_seq_from_1(
    commands: list[tuple[str, ...]],
) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        repo = make_repo(Path(tmp))
        notes = Path(tmp) / "notes"
        _ = ok(repo, "init", "--notes", str(notes))
        log = notes / "events.jsonl"
        for command in commands:
            before = log.read_text()
            argv = ("init", "--notes", str(notes)) if command == ("init",) else command

            code, out, _ = run(repo, *argv)

            after = log.read_text()
            assert after.startswith(before)
            appended = after[len(before) :].splitlines()
            reported = [
                line for line in out.splitlines() if line.startswith("recorded ")
            ]
            assert len(appended) == (len(reported) if code == 0 else 0)
        seqs = [line["seq"] for line in log_of(notes)]
        assert seqs == list(range(1, len(seqs) + 1))


def test_init_creates_the_notes_dir_and_a_started_line(
    repo: Path, tmp_path: Path
) -> None:
    notes = tmp_path / "engineer-owner-repo-slug"

    out = ok(repo, "init", "--notes", str(notes))

    assert out == f"{notes}/events.jsonl\nstarted: yes\n"
    [line] = log_of(notes)
    assert line["seq"] == 1
    assert line["event"] == {"type": "started", "notes": str(notes), "delegated": False}


def test_init_twice_appends_nothing_and_exits_0(repo: Path, tmp_path: Path) -> None:
    notes = tmp_path / "notes"
    _ = ok(repo, "init", "--notes", str(notes))
    before = (notes / "events.jsonl").read_text()

    out = ok(repo, "init", "--notes", str(notes))

    assert out == f"{notes}/events.jsonl\nstarted: already\n"
    assert (notes / "events.jsonl").read_text() == before


def test_a_line_carries_seq_head_and_the_runners_session(
    repo: Path, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("STATE_SESSION", "s-42")
    head = commit(repo, {"b.txt": "b\n"}, "work")

    _ = ok(repo, "init", "--notes", str(tmp_path / "notes"))

    [line] = log_of(tmp_path / "notes")
    assert (line["head"], line["session"]) == (head, "s-42")


def test_record_prints_each_appended_line_and_the_state_it_reaches(
    repo: Path, tmp_path: Path
) -> None:
    _ = ok(repo, "init", "--notes", str(tmp_path / "notes"))

    out = ok(repo, "record", "size", "Normal")

    assert out == "recorded 2 size -> Ctx\n"


def test_drafting_with_quality_unset_records_it_defaulted(
    repo: Path, tmp_path: Path
) -> None:
    for argv in (
        ("init", "--notes", str(tmp_path / "notes")),
        ("record", "size", "Normal"),
        ("record", "planned", "p.md"),
        ("record", "confirmed"),
    ):
        _ = ok(repo, *argv)

    out = ok(repo, "record", "drafted", "7", "main")

    assert out == "recorded 5 defaulted -> Impl\nrecorded 6 drafted -> Impl\n"
    assert "Quality: Balanced (defaulted)" in ok(repo, "show")


def test_an_event_off_the_table_exits_2_and_appends_nothing(
    repo: Path, tmp_path: Path
) -> None:
    _ = ok(repo, "init", "--notes", str(tmp_path / "notes"))

    code, _, err = run(repo, "record", "ready", "7")

    assert code == 2
    assert err.startswith("state record: 'ready' is not an arrow out of Ctx\nfix: ")
    assert len(log_of(tmp_path / "notes")) == 1


@pytest.mark.parametrize(
    ("bad", "why"),
    [
        pytest.param("{not json\n", "not JSON", id="not JSON"),
        pytest.param('{"seq":3}', "no newline at its end", id="no newline"),
        pytest.param(
            '{"seq":9,"ts":"t","head":null,"session":null,"event":{"type":"confirmed"}}\n',
            "seq is 9, expected 3", id="a seq gap",
        ),
        pytest.param(
            '{"seq":3,"ts":"t","head":null,"session":null,"event":{"type":"shipped"}}\n',
            "unknown event type 'shipped'", id="an unknown event",
        ),
        pytest.param(
            ('{"seq":3,"ts":"t","head":null,"session":null,'
            '"event":{"type":"asked","n":1,"extra":1}}\n'),
            "unknown ['extra']", id="an unknown field",
        ),
        pytest.param(
            '{"seq":3,"ts":"t","head":null,"session":null,"event":{"type":"asked","n":0}}\n',
            "n is not a positive integer", id="a bad value",
        ),
    ],
)  # fmt: skip
@pytest.mark.parametrize("command", [("next",), ("show",), ("record", "asked")])
def test_a_hand_edited_bad_line_makes_every_command_exit_2_naming_it(
    repo: Path, tmp_path: Path, bad: str, why: str, command: tuple[str, ...]
) -> None:
    notes = tmp_path / "notes"
    _ = ok(repo, "init", "--notes", str(notes))
    _ = ok(repo, "record", "size", "Normal")
    log = notes / "events.jsonl"
    with log.open("a") as file:
        _ = file.write(bad)

    code, out, err = run(repo, *command)

    assert (code, out) == (2, "")
    message, fix = err.splitlines()
    assert message.startswith(f"state: {log}:3: ") and why in message
    assert fix == (
        f"fix: repair or delete line 3 of {log}: the log is append-only, so a bad "
        "line is a hand edit"
    )


def test_override_moves_the_state_and_next_advises_its_arrow(
    repo: Path, tmp_path: Path
) -> None:
    _ = ok(repo, "init", "--notes", str(tmp_path / "notes"))

    out = ok(repo, "override", "Impl", "the plan is in the issue")

    assert out == "recorded 2 overridden -> Impl\n"
    assert first_line(ok(repo, "next")) == "SPAWN implementer"


def test_handback_fixer_records_blocked_then_fixed(repo: Path, tmp_path: Path) -> None:
    notes = tmp_path / "notes"
    to_impl(repo, notes)
    _ = ok(repo, "record", "implemented")
    _ = ok(repo, "record", "refactored")
    _ = ok(
        repo, "handback", "review-lead", "--row", "R1", stdin="x\nReviewed head: abc\n"
    )

    blocked = ok(
        repo, "handback", "fixer", "--kind", "fact", stdin="NEEDS_DECISION q?\n"
    )
    fixed = ok(repo, "handback", "fixer", stdin="READY\n")

    assert (blocked, fixed) == (
        "recorded 10 blocked -> Impl''\n",
        "recorded 11 fixed -> Impl''\n",
    )
    assert log_of(notes)[8]["event"] == {
        "type": "reviewed", "head": "abc", "rows": ["R1"], "verdicts": [],
    }  # fmt: skip


def test_next_skips_the_refactor_on_a_small_balanced_diff(
    repo: Path, tmp_path: Path
) -> None:
    to_impl(repo, tmp_path / "notes")
    _ = commit(repo, {"b.txt": "x\n" * 60, "flake.lock": "y\n" * 500}, "work")
    _ = ok(repo, "record", "implemented")

    out = ok(repo, "next")

    assert first_line(out) == "SPAWN review-lead"
    assert "  refactor skipped: 60 changed lines, Balanced" in out.splitlines()


def test_next_refactors_a_large_balanced_diff_and_dry_runs_a_new_skill(
    repo: Path, tmp_path: Path
) -> None:
    to_impl(repo, tmp_path / "notes")
    _ = commit(repo, {"b.txt": "x\n" * 101}, "work")
    _ = ok(repo, "record", "implemented")
    refactor = first_line(ok(repo, "next"))
    _ = commit(repo, {"skills/new/SKILL.md": "# New\n"}, "skill")
    _ = ok(repo, "record", "refactored")

    review = ok(repo, "next")

    assert refactor == "SPAWN refactorer"
    assert "also: SPAWN reviewer" in review


def test_brief_refactorer_holds_the_mechanics_and_the_stop_rule_verbatim(
    repo: Path, tmp_path: Path
) -> None:
    to_impl(repo, tmp_path / "notes")

    out = ok(repo, "brief", "refactorer")

    lines = out.splitlines()
    assert lines[:5] == [
        "run `refactor` with: Quality: Balanced",
        "Size: Normal",
        f"Worktree: {repo} (every command runs here)",
        "Base: origin/main",
        f"Plan: {tmp_path / 'notes'}/plan.md",
    ]
    assert stop_rule_of(BLOCKERS.read_text()) in out
    assert lines[-1].startswith("Hand back in about 250 words, never over 300")


def test_brief_review_lead_gets_the_plan_wrong_line_not_the_stop_rule(
    repo: Path, tmp_path: Path
) -> None:
    to_impl(repo, tmp_path / "notes")

    out = ok(repo, "brief", "review-lead")

    assert "`NEEDS_DECISION plan wrong: <finding>`" in out
    assert stop_rule_of(BLOCKERS.read_text()) not in out


def test_show_prints_the_progress_view(repo: Path, tmp_path: Path) -> None:
    notes = tmp_path / "notes"
    to_impl(repo, notes)
    _ = ok(repo, "record", "implemented", "h1")
    _ = ok(repo, "record", "refactored", "h2")
    _ = ok(repo, "record", "reviewed", "h3", "--row", "R1")
    _ = ok(repo, "record", "blocked", "fact", "fixer", "which log?")

    out = ok(repo, "show")

    assert out.splitlines() == [
        "Step: Impl''",
        "Head: h3",
        "Quality: Balanced",
        "Size: Normal",
        "Re-review: 0/2   (round 1 is the first review, not counted)",
        "Reviewed head: h3",
        f"Notes: {notes}  Plan: {notes}/plan.md  PR: 7  Base: main",
        "Researched: 0  Asked: 0",
        "Rounds:",
        "- review 1 - h3 - R1",
        "Blockers:",
        "- which log? - fact - open",
    ]


def test_a_command_before_init_exits_2_naming_init(repo: Path) -> None:
    code, _, err = run(repo, "next")

    assert code == 2
    assert err == (
        "state: no run in this worktree\n"
        "fix: state init --notes /tmp/engineer-<owner>-<repo>-<slug>\n"
    )


def test_outside_a_repo_exits_2(tmp_path: Path) -> None:
    code, _, err = run(tmp_path, "next")

    assert code == 2
    assert err.splitlines()[1] == "fix: cd <worktree>; state keeps one run per worktree"


@pytest.mark.parametrize(
    "argv",
    [
        ("bogus",),
        ("init",),
        ("record",),
        ("record", "quality", "Great"),
        ("brief", "pm"),
    ],
)
def test_bad_usage_exits_2_with_a_fix_line(repo: Path, argv: tuple[str, ...]) -> None:
    code, out, err = run(repo, *argv)

    assert (code, out) == (2, "")
    assert err.splitlines()[1].startswith("fix: ")


def test_help_prints_usage_and_exits_0(repo: Path) -> None:
    code, out, err = run(repo, "help")

    assert (code, err) == (0, "")
    assert out.splitlines()[0] == (
        "state - record the engineer flow as events; advise the next arrow"
    )
    assert "  state next " in out


def test_render_prints_the_states_block(repo: Path) -> None:
    assert ok(repo, "render") == render()
