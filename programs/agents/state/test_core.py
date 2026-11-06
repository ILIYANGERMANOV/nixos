"""The issue's laws as properties over generated event lists, the transition
table row by row and the hand-back parser on real first lines."""

import pytest
from core import (
    Advice,
    Facts,
    GitFacts,
    HandbackOptions,
    NoFacts,
    advise,
    apply,
    fold,
    parse_handback,
    render_advice,
    show,
)
from hypothesis import given
from hypothesis import strategies as st
from model import (
    S0,
    STATES,
    Blocked,
    Ci,
    Confirmed,
    Defaulted,
    Event,
    Failure,
    Fixed,
    Grew,
    Implemented,
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
)
from state_fixtures import (
    NOTES,
    accepted,
    advice,
    drafted,
    event_lists,
    events,
    facts,
    final_fixed,
    first_line,
    heads,
    labels,
    reach,
    reviewed,
    walk,
)

TOKENS = ("SPAWN ", "ASK ", "WAIT ", "RUN ", "STUCK ", "DONE")


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
