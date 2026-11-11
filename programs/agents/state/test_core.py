"""The issue's laws as properties over generated event lists, the transition
table row by row and the hand-back parser on real first lines."""

from dataclasses import replace
from typing import Literal

import pytest
from hypothesis import given
from hypothesis import strategies as st

from state.core import (
    PR_STATES,
    Accepted,
    Advice,
    Facts,
    GitFacts,
    HandbackOptions,
    NoFacts,
    Pr,
    Refusal,
    advise,
    apply,
    brief,
    decide,
    fold,
    off_branch,
    parse_handback,
    record,
    render_advice,
    show,
    synced,
    warning,
)
from state.model import (
    MODES,
    ROLES,
    S0,
    SIZES,
    STATES,
    Adjusted,
    Asked,
    Blocked,
    Ci,
    Confirmed,
    Defaulted,
    Drafted,
    Event,
    Failure,
    Fixed,
    Grew,
    Implemented,
    Mode,
    OpenBlocker,
    Overridden,
    Planned,
    Proposed,
    Quality,
    Raised,
    Ready,
    Refactored,
    Refused,
    Researched,
    Resolved,
    Reviewed,
    Role,
    Simplified,
    Size,
    SizeName,
    Started,
    State,
    StateName,
    Verdict,
)
from state.state_fixtures import (
    NOTES,
    OVERRIDE,
    PR,
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
    pr_urls,
    reach,
    review,
    reviewed,
    simplified,
    then,
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


@given(
    step=st.sampled_from(STATES),
    mode=st.sampled_from(MODES),
    size=st.sampled_from(SIZES),
    delegated=st.booleans(),
    git=facts,
)
def test_advisory_every_step_in_every_quality_and_size_advises_an_arrow_with_its_payload(
    *, step: StateName, mode: Mode, size: SizeName, delegated: bool, git: Facts
) -> None:
    run = (
        Started(NOTES, delegated=delegated),
        Size(size),
        Quality(mode),
        Overridden(step, "why"),
    )

    lines = advice(*run, facts=git).splitlines()

    assert lines[0].startswith(TOKENS)
    assert lines[1].startswith("  ")


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


STAY = (Quality, Size, Grew, Defaulted, Researched, Resolved, Refused)


@given(event_lists)
def test_fixed_targets_knobs_counts_and_triage_never_move_the_step(
    candidates: list[Event],
) -> None:
    stays = [
        (before.step, after.step)
        for before, event, after in walk(candidates)
        if isinstance(event, STAY)
        or (isinstance(event, Blocked) and event.kind != "decision")
    ]

    assert all(before == after for before, after in stays)


@given(event_lists)
def test_fixed_targets_a_leads_decision_goes_back_to_ctx(
    candidates: list[Event],
) -> None:
    targets = [
        after.step
        for _, event, after in walk([Started(NOTES, delegated=False), *candidates])
        if isinstance(event, Blocked) and event.kind == "decision"
    ]

    assert all(step == "Ctx" for step in targets)


@given(event_lists)
def test_fixed_targets_a_delegated_decision_never_moves_the_step(
    candidates: list[Event],
) -> None:
    stays = [
        (before.step, after.step)
        for before, event, after in walk([Started(NOTES, delegated=True), *candidates])
        if isinstance(event, Blocked) and event.kind == "decision"
    ]

    assert all(before == after for before, after in stays)


@given(heads, heads, labels, st.lists(labels, max_size=2))
def test_stuck_guard_the_same_row_in_two_rounds_in_a_row_is_stuck(
    first: str, second: str, row: str, others: list[str]
) -> None:
    text = advice(
        *drafted("Max"),
        Implemented("h1"),
        Refactored("h2"),
        *review(first, (row,), ()),
        Fixed("h4", ()),
        *review(second, (*others, row), ()),
    )

    assert first_line(text) == f"STUCK row {row} in 2 rounds in a row"
    assert (
        f"state record blocked decision <role> 'stuck: row {row} in 2 rounds in a row'"
    ) in text


@given(heads, heads)
def test_stuck_guard_the_same_failing_check_twice_is_stuck(
    first: str, second: str
) -> None:
    text = advice(
        *reviewed("POC"),
        Fixed("h4", ()),
        *review("h5", (), ()),
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
        *review("h3", ("R1",), ()),
        Fixed("h4", ()),
        *review("h5", ("R2",), ()),
    )

    assert first_line(text) == "SPAWN fixer"


def test_stuck_guard_different_failing_checks_in_two_rounds_are_not_stuck() -> None:
    text = advice(
        *reviewed("POC"),
        Fixed("h4", ()),
        *review("h5", (), ()),
        Fixed("h6", ()),
        Ci("h6", ("lint",)),
        Fixed("h7", ()),
        Ci("h7", ("test",)),
    )

    assert first_line(text) == "SPAWN fixer"


def test_stuck_guard_different_questions_in_a_row_are_not_stuck() -> None:
    text = advice(
        *drafted(),
        Blocked("which log?", "answered", "implementer"),
        Resolved("which log?", "the notes dir"),
        Blocked("which branch?", "answered", "implementer"),
    )

    assert not first_line(text).startswith("STUCK ")


def test_stuck_guard_the_same_question_back_after_it_closed_is_stuck() -> None:
    text = advice(
        *drafted(),
        Blocked("which log?", "answered", "implementer"),
        Resolved("which log?", "the notes dir"),
        Blocked("which log?", "answered", "implementer"),
    )

    assert first_line(text) == "STUCK question 'which log?' back in 2 rounds in a row"


def the_same_row_twice(row: str, first: str, second: str) -> list[Event]:
    return [
        *drafted("Max"),
        Implemented("h1"),
        Refactored("h2"),
        *review(first, (row,), ()),
        Fixed("h4", ()),
        *review(second, (row,), ()),
    ]


def the_same_check_twice(check: str, first: str, second: str) -> list[Event]:
    return [
        *reviewed("POC"),
        Fixed("h4", ()),
        *review("h5", (), ()),
        Fixed("h6", ()),
        Ci(first, (check,)),
        Fixed("h7", ()),
        Ci(second, (check,)),
    ]


stuck_runs = st.one_of(
    st.builds(the_same_row_twice, labels, heads, heads),
    st.builds(the_same_check_twice, st.sampled_from(["lint", "test"]), heads, heads),
)


@given(run=stuck_runs, role=st.sampled_from(ROLES), answered=st.booleans())
def test_stuck_guard_a_stuck_answered_as_a_decision_is_not_stuck_again(
    *, run: list[Event], role: Role, answered: bool
) -> None:
    before = first_line(advice(*run))
    assert before.startswith("STUCK ")  # the run is stuck before the decision
    question = f"stuck: {before.removeprefix('STUCK ')}"
    answer = [Resolved(question, "drop it")] if answered else []

    text = advice(*run, Blocked(question, "decision", role), *answer)

    assert not first_line(text).startswith("STUCK ")


@given(
    st.lists(events.filter(lambda e: not isinstance(e, Overridden)), max_size=40), facts
)
def test_delegated_never_asks_never_plans_and_always_reports(
    candidates: list[Event], git: Facts
) -> None:
    state = reach(*accepted([Started(NOTES, delegated=True), *candidates]))

    lines = render_advice(advise(state, git)).splitlines()

    assert not lines[0].startswith("ASK ")
    assert not any("state record planned" in line for line in lines)
    assert lines[-1] == "  after each step: state show > <the brief's report file>"


def test_stuck_guard_delegated_hands_the_stuck_back() -> None:
    text = advice(
        *drafted("Max", delegated=True),
        Implemented("h1"),
        Refactored("h2"),
        *review("h3", ("R1",), ()),
        Fixed("h4", ()),
        *review("h5", ("R1",), ()),
    )

    assert text.splitlines()[1] == (
        "  hand back: NEEDS_DECISION stuck: row R1 in 2 rounds in a row, the work pushed"
    )


# ---- The table, row by row ----------------------------------------------------------


def ci_fix_reviewed_at_cap(
    rows: tuple[str, ...], verdicts: tuple[Verdict, ...]
) -> list[Event]:
    """A POC run in PR, its one re-review spent on a CI fix's review."""
    return [
        *final_fixed("POC"),
        Ci("h4", ("lint",)),
        Fixed("h5", ()),
        *review("h6", rows, verdicts),
    ]


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
            "ASK quality", "when nothing is open, before plan.md:",
            id="Ctx: Quality asked before the plan",
        ),
        pytest.param(
            [Started(NOTES, delegated=False), Size("Normal"), Quality("Balanced")], NoFacts(),
            f"RUN state record planned {NOTES}/plan.md",
            "researchers 0 (at least 1, typically 2-3; Balanced: up to 3, 15 calls, notes)",
            id="Ctx: research and ask, then the plan",
        ),
        pytest.param(
            [Started(NOTES, delegated=False), Size("Trivial"), Quality("POC")], NoFacts(),
            f"RUN state record planned {NOTES}/plan.md",
            "researchers 0 (Trivial: none, at most 5 lookups by you)",
            id="Ctx: Trivial researches nothing",
        ),
        pytest.param(
            [Started(NOTES, delegated=False), Size("Normal"), Planned("p.md")], NoFacts(),
            "ASK quality", "POC, Balanced (Recommended), Max",
            id="Propose: Quality asked once",
        ),
        pytest.param(
            [Started(NOTES, delegated=False), Size("Normal"), Planned("p.md"), Quality("Balanced")],
            NoFacts(), "SPAWN researcher", "modes: simplify, alternative  Quality: Balanced",
            id="Propose: Balanced proposals",
        ),
        pytest.param(
            [Started(NOTES, delegated=False), Size("Normal"), Planned("p.md"), Quality("POC")],
            NoFacts(), "SPAWN researcher", "modes: simplify  Quality: POC",
            id="Propose: POC simplifies only",
        ),
        pytest.param(
            [
                Started(NOTES, delegated=False), Size("Normal"), Planned("p.md"), Quality("Max"),
                Proposed("simplify"), Proposed("alternative"),
            ],
            NoFacts(), "ASK plan", '"First plan", "Second plan", "Adjust"',
            id="Propose: proposals back, ask the plan",
        ),
        pytest.param(
            [Started(NOTES, delegated=False), Size("Trivial"), Planned("p.md")], NoFacts(),
            "RUN state record confirmed", "Trivial: no proposals",
            id="Propose: Trivial confirms itself",
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
            id="Implement: implementers",
        ),
        pytest.param(
            drafted("POC"), NoFacts(), "SPAWN implementer",
            "POC: one implementer, one happy-path proof as its test", id="Implement: POC",
        ),
        pytest.param(
            [*drafted("Max"), Implemented("h1")], GitFacts(10, "none"),
            "SPAWN refactorer", "Max: always", id="Refactor: Max always refactors",
        ),
        pytest.param(
            [*drafted("Max"), Implemented("h1")], GitFacts(10, "none"), "SPAWN refactorer",
            "proposals: one AskUserQuestion for all, in this PR / a follow-up / drop",
            id="Refactor: the user decides all proposals in one question",
        ),
        pytest.param(
            [*drafted("Max", delegated=True), Implemented("h1")], GitFacts(10, "none"),
            "SPAWN refactorer", "proposals: hand them back to your caller",
            id="Refactor: delegated, the proposals go to the caller",
        ),
        pytest.param(
            [*drafted(), Implemented("h1")], GitFacts(100, "none"), "SPAWN review-lead",
            "refactor skipped: 100 changed lines, Balanced",
            id="Refactor: Balanced skips at 100 lines",
        ),
        pytest.param(
            [*drafted(), Implemented("h1")], GitFacts(101, "none"), "SPAWN refactorer",
            "Balanced: above about 100 changed lines", id="Refactor: Balanced above 100",
        ),
        pytest.param(
            [*drafted(), Implemented("h1"), Fixed("h2", ())], GitFacts(101, "none"),
            "SPAWN refactorer", "Balanced: above about 100 changed lines",
            id="Refactor: a fix before the refactor still refactors",
        ),
        pytest.param(
            [*drafted("POC"), Implemented("h1")], GitFacts(5, "none"), "SPAWN refactorer",
            "POC: quick: items 1-3, no `tests.md`", id="Refactor: POC refactors quick",
        ),
        pytest.param(
            [*drafted("Max", "Trivial"), Implemented("h1")], GitFacts(500, "none"),
            "SPAWN review-lead", "refactor skipped: Trivial", id="Refactor: Trivial skips",
        ),
        pytest.param(
            [*drafted(), Implemented("h1"), Refactored("h2")], GitFacts(5, "none"),
            "SPAWN review-lead",
            ("invoke `pragmatic-review` with: Quality: Balanced Size: Normal "
            f"--requirements {NOTES}/requirements.md {PR}"),
            id="Review: the first review",
        ),
        pytest.param(
            [*drafted(), Implemented("h1"), Refactored("h2"), Implemented("h3")],
            GitFacts(5, "none"), "SPAWN review-lead",
            ("invoke `pragmatic-review` with: Quality: Balanced Size: Normal "
            f"--requirements {NOTES}/requirements.md {PR}"),
            id="Review: a late slice still gets the whole-branch first review",
        ),
        pytest.param(
            [*drafted(), Implemented("h1"), Refactored("h2")], GitFacts(5, "none"),
            "SPAWN review-lead",
            "back: recorded by the hook; then: state record picked [--row <label>]...",
            id="Review: the hook records the review, the lead picks its rows",
        ),
        pytest.param(
            [*drafted(), Implemented("h1"), Refactored("h2")], GitFacts(5, "new"),
            "SPAWN review-lead", "also: SPAWN reviewer",
            id="Review: Balanced dry-runs a new skill",
        ),
        pytest.param(
            [*drafted(), Implemented("h1"), Refactored("h2")], GitFacts(5, "changed"),
            "SPAWN review-lead", "a dry run only if it is rewritten",
            id="Review: Balanced asks whether a changed skill is rewritten",
        ),
        pytest.param(
            [*drafted("Max"), Implemented("h1"), Refactored("h2")],
            GitFacts(5, "changed"), "SPAWN review-lead", "also: SPAWN reviewer",
            id="Review: Max dry-runs any skill change",
        ),
        pytest.param(
            reviewed(), NoFacts(), "SPAWN fixer", "rows: R1, R2",
            id="Fix: fix the chosen rows",
        ),
        pytest.param(
            [*reviewed(), Fixed("h4", ())], NoFacts(), "SPAWN review-lead",
            ("invoke `pragmatic-review` with: Quality: Balanced Size: Normal --fixes h3 "
            f"--requirements {NOTES}/requirements-fixes.md {PR}"),
            id="Fix: a --fixes review of the previous Reviewed head",
        ),
        pytest.param(
            [*reviewed(), Fixed("h4", ("interface",))], NoFacts(), "SPAWN review-lead",
            "--fixes h3", id="Fix: Balanced keeps --fixes for an interface fix",
        ),
        pytest.param(
            [*reviewed(), Fixed("h4", ("auth",))], NoFacts(), "SPAWN review-lead",
            "a fix to auth: a first review of the whole branch, a round",
            id="Fix: an auth fix gets a whole-branch review",
        ),
        pytest.param(
            [
                *reviewed(), Fixed("h4", ()), *review("h5", ("R3",), ()),
                Fixed("h6", ()), *review("h7", ("R4",), ()),
            ],
            NoFacts(), "SPAWN fixer", "final fixer: rows R4, R0; nothing reviews it",
            id="Fix: Balanced's cap of 2 re-reviews goes to the final fixer",
        ),
        pytest.param(
            [*reviewed("POC"), Fixed("h4", ()), *review("h5", ("R3",), ())],
            NoFacts(), "SPAWN fixer", "final fixer: rows R3, R0",
            id="Fix: POC's cap of 1",
        ),
        pytest.param(
            [
                *reviewed("POC"), Fixed("h4", ()),
                *review("h5", ("R3",), (Verdict("AC1", "not-met"),)),
            ],
            NoFacts(), "SPAWN fixer", "at the cap: fix only Not met AC1",
            id="Fix: Not met loops even at the cap",
        ),
        pytest.param(
            [*drafted(), Implemented("h1"), Refactored("h2"), *review("h3", (), ())],
            NoFacts(), "SPAWN fixer", "final fixer: rows R0", id="Review: no rows",
        ),
        pytest.param(
            [*drafted("Max", "Trivial"), Implemented("h1"), *review("h3", ("R1",), ())],
            NoFacts(), "SPAWN fixer", "final fixer: rows R1, R0",
            id="Refactor: Trivial has no re-review",
        ),
        pytest.param(
            final_fixed(), NoFacts(), "SPAWN fixer", "CI runs meanwhile: state record ci",
            id="DraftPR: S0 while CI runs",
        ),
        pytest.param(
            final_fixed(delegated=True), NoFacts(), "SPAWN fixer", "row S0: shorten the PR body",
            id="DraftPR: delegated runs S0 too",
        ),
        pytest.param(
            simplified(), NoFacts(), "WAIT ci", "notify: the draft is complete and CI runs",
            id="DraftPR: simplified, notify and wait for CI",
        ),
        pytest.param(
            simplified(delegated=True), NoFacts(), "DONE", f"hand back: READY {PR}, the work pushed",
            id="DraftPR: delegated hands back once simplified",
        ),
        pytest.param(
            [*simplified(), Ci("h4", ())], NoFacts(), f"RUN gh pr ready {PR}", "then: state next, which records ready from the PR on GitHub",
            id="PR: green CI and simplified, ready",
        ),
        pytest.param(
            [*final_fixed(), Ci("h4", ()), Simplified("h4")], NoFacts(), f"RUN gh pr ready {PR}", "before:",
            id="PR: S0 back after green CI, ready",
        ),
        pytest.param(
            [*final_fixed(), Ci("h4", ())], NoFacts(), "SPAWN fixer", "row S0: shorten the PR body",
            id="PR: green CI before S0 gets S0, not ready",
        ),
        pytest.param(
            [*simplified("POC"), Ci("h4", ())], NoFacts(), "DONE", "the PR stays a labelled draft", id="PR: POC stays a draft",
        ),
        pytest.param(
            [*simplified(), Ci("h4", ("lint",)), Fixed("h5", ()), *review("h6"), Ci("h6", ())],
            NoFacts(), f"RUN gh pr ready {PR}", "before:",
            id="PR: a CI fix keeps simplified",
        ),
        pytest.param(
            [*simplified(), Ci("h4", ("lint",))], NoFacts(), "SPAWN fixer", "keep the S0 shape",
            id="PR: a CI fix after S0 edits the body in place",
        ),
        pytest.param(
            [*final_fixed(), Ci("h4", ("lint",))], NoFacts(), "SPAWN fixer", "with the full facts",
            id="PR: a CI fix before S0 writes the full body",
        ),
        pytest.param(
            [*final_fixed(), Ci("h4", ("lint",))], NoFacts(), "SPAWN fixer", "CI fix: lint", id="PR: CI fix",
        ),
        pytest.param(
            [*final_fixed(), Ci("h4", ("lint",)), Fixed("h5", ())],
            NoFacts(), "SPAWN review-lead", "a --fixes review of the fix",
            id="PR: a CI fix gets a --fixes review",
        ),
        pytest.param(
            [
                *final_fixed(), Ci("h4", ("lint",)), Fixed("h5", ()),
                *review("h6", (), (Verdict("AC1", "not-met"),)),
            ],
            NoFacts(), "SPAWN fixer", "rows: -", id="PR: a Not met with no rows gets a fixer",
        ),
        pytest.param(
            ci_fix_reviewed_at_cap(("R3",), (Verdict("AC1", "not-met"),)),
            NoFacts(), "SPAWN fixer", "at the cap: fix only Not met AC1",
            id="PR: Not met loops even at the cap",
        ),
        pytest.param(
            [*ci_fix_reviewed_at_cap(("R3",), (Verdict("AC1", "not-met"),)), Fixed("h7", ())],
            NoFacts(), "SPAWN review-lead", "a --fixes review of the fix",
            id="PR: a Not met fix at the cap gets a --fixes review",
        ),
        pytest.param(
            ci_fix_reviewed_at_cap(("R3",), ()), NoFacts(), "SPAWN fixer", "final fixer: rows R3, R0",
            id="PR: rows at the cap go to the final fixer",
        ),
        pytest.param(
            [*ci_fix_reviewed_at_cap(("R3",), ()), Fixed("h7", ())], NoFacts(), "WAIT ci",
            "gh pr checks", id="PR: after the final fixer, the CI wait",
        ),
        pytest.param(
            [*simplified(), Ci("h4", ()), Ready(PR)], NoFacts(), "DONE", "the PR is ready", id="Done",
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
            id="blocker: delegated decision hands back, no re-plan",
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
            NoFacts(), "ASK plan", f"picked, a re-plan: gh pr edit {PR} --body-file",
            id="re-plan: the chosen plan goes into the PR body",
        ),
        pytest.param(
            [*drafted("Max"), Implemented("h1"), Refactored("h2"), *review("h3", ("R1",), ()),
             Fixed("h4", ()), *review("h5", ("R1",), ()),
             Blocked("stuck: row R1", "decision", "review-lead")],
            NoFacts(), f"RUN state record planned {NOTES}/plan.md",
            "decision path for 'stuck: row R1'", id="stuck: the answer is a decision, a re-plan",
        ),
        pytest.param(
            [*drafted("Max"), Implemented("h1"), Refactored("h2"), *review("h3", ("R1",), ()),
             Fixed("h4", ()), *review("h5", ("R1",), ()),
             Blocked("stuck: row R1", "decision", "review-lead"),
             Resolved("stuck: row R1", "drop the row")],
            NoFacts(), "SPAWN review-lead", "brief: state brief review-lead",
            id="stuck: a dropped row resumes Fix, no fixer for it",
        ),
        pytest.param(
            [*drafted(delegated=True), Implemented("h1"),
             Blocked("plan wrong: x", "decision", "review-lead"), Resolved("plan wrong: x", "y")],
            NoFacts(), "SPAWN refactorer", "brief: state brief refactorer",
            id="blocker: delegated, resumed with the answer at its step",
        ),
        pytest.param(
            [*drafted("Max", delegated=True), Implemented("h1"), Refactored("h2"),
             *review("h3", ("R1",), ()), Fixed("h4", ())],
            NoFacts(), "SPAWN review-lead",
            "<the brief's requirements file's directory>/<the brief's task>-fixes.md",
            id="Fix: delegated fixes copy beside the brief's requirements",
        ),
    ],
)  # fmt: skip
def test_next_advises_the_tables_arrow_with_its_payload(
    run: list[Event], git: Facts, line1: str, payload: str
) -> None:
    text = advice(*run, facts=git)

    assert first_line(text) == line1
    assert payload in text


def test_a_confirmed_re_plan_resumes_at_implement_and_restarts_the_rounds() -> None:
    state = reach(
        *reviewed(),
        Fixed("h4", ()),
        *review("h5", ("R3",), ()),
        Blocked("plan wrong: x", "decision", "review-lead"),
        Planned("p2.md"),
        Proposed("simplify"),
        Proposed("alternative"),
        Confirmed(),
    )

    assert state.step == "Implement"
    assert "Re-review: 0/2" in show(state)


DECISION = Blocked("which api?", "decision", "implementer")
ANSWERED = Resolved("which api?", "the old one")
SECOND = Blocked("which db?", "decision", "researcher")


@given(event_lists)
def test_history_a_resolved_decision_resumes_the_step_it_came_from(
    candidates: list[Event],
) -> None:
    lead = [
        state
        for _, _, state in walk([Started(NOTES, delegated=False), *candidates])
        if state.run == Started(NOTES, delegated=False)
        and state.step not in ("Ctx", "Done")
        and not any(
            isinstance(b, OpenBlocker) and b.kind == "decision" for b in state.blockers
        )
    ]
    resumed = [then(state, DECISION, ANSWERED).step for state in lead]

    assert resumed == [state.step for state in lead]


def reach_from(step: StateName, *events: Event) -> StateName:
    """The step `events` reach from a lead's run overridden to `step`."""
    return reach(Started(NOTES, delegated=False), Overridden(step, "why"), *events).step


@pytest.mark.parametrize("step", ["Fix", "Review"])
def test_history_resolved_returns_to_the_step_the_decision_came_from(
    step: StateName,
) -> None:
    assert reach_from(step, DECISION, ANSWERED) == step


def test_history_a_decision_raised_in_ctx_resolves_in_ctx() -> None:
    assert reach(Started(NOTES, delegated=False), DECISION, ANSWERED).step == "Ctx"


def test_history_a_second_decision_keeps_the_first_origin() -> None:
    assert reach_from("Fix", DECISION, SECOND, ANSWERED,
                      Resolved("which db?", "pg")) == "Fix"  # fmt: skip


def test_history_resolved_stays_in_ctx_while_a_decision_is_open() -> None:
    assert reach_from("Fix", DECISION, SECOND, ANSWERED) == "Ctx"


def test_history_a_re_plan_forgets_the_origin() -> None:
    assert reach_from("Fix", DECISION, Planned("p2.md"), Adjusted(), ANSWERED) == "Ctx"


def test_history_a_re_plan_from_a_decision_still_resumes_at_implement() -> None:
    state = reach(
        *reviewed(), Fixed("h4", ()), *review("h5", ("R3",), ()), DECISION,
        Planned("p2.md"), Proposed("simplify"), Proposed("alternative"), Confirmed(),
    )  # fmt: skip

    assert state.step == "Implement"


def test_next_in_ctx_after_a_decision_names_both_ways_out() -> None:
    text = advice(*reviewed(), DECISION)

    assert first_line(text) == f"RUN state record planned {NOTES}/plan.md"
    assert (
        "no plan change: state record resolved 'which api?' <answer>, back to Fix"
        in text
    )


# An implementer used for a CI fix hands back `implemented`, not `fixed`.
@pytest.mark.parametrize(
    ("run", "step"),
    [(final_fixed(), "DraftPR"), ([*simplified(), Ci("h5", ("lint",))], "PR")],
)
def test_an_implemented_hand_back_in_draftpr_or_pr_is_a_fix_that_stays_put(
    run: list[Event], step: StateName
) -> None:
    state = then(reach(*run), Implemented("h9"))

    assert (state.step, state.head) == (step, "h9")
    assert first_line(advice(*run, Implemented("h9"))) == first_line(
        advice(*run, Fixed("h9", ()))
    )


def test_a_re_plan_keeps_the_stuck_history() -> None:
    text = advice(
        *drafted("Max"),
        Implemented("h1"),
        Refactored("h2"),
        *review("h3", ("R1",), ()),
        Blocked("plan wrong: x", "decision", "review-lead"),
        Planned("p2.md"),
        Confirmed(),
        Implemented("h4"),
        Refactored("h5"),
        *review("h6", ("R1",), ()),
    )

    assert first_line(text) == "STUCK row R1 in 2 rounds in a row"


def test_quality_is_set_once() -> None:
    assert isinstance(fold([Quality("POC"), Quality("Max")]), Failure)


def test_size_never_shrinks_to_trivial() -> None:
    assert isinstance(fold([Size("Normal"), Size("Trivial")]), Failure)


def test_a_trivial_task_that_grew_is_normal() -> None:
    assert reach(Size("Trivial"), Grew("a migration")).size == "Normal"


def test_an_event_off_the_table_is_an_error_naming_the_arrows_and_the_override() -> (
    None
):
    match fold([Started(NOTES, delegated=False), Ready(PR)]):
        case Failure(message=message, fix=fix, code=code):
            assert (message, code) == ("event 2: 'ready' is not an arrow out of Ctx", 2)
            assert fix == (
                "here: state record asked | planned; "
                'to record ready: state override PR "<why>", then rerun'
            )
        case State():
            raise AssertionError("ready is no arrow out of Ctx")


def test_an_ask_from_propose_names_the_override_back_to_ctx() -> None:
    match fold([Started(NOTES, delegated=False), Planned("p.md"), Asked(1)]):
        case Failure(fix=fix):
            assert fix == (
                "here: state record proposed | confirmed | adjusted; "
                'to record asked: state override Ctx "<why>", then rerun'
            )
        case State():
            raise AssertionError("asked is no arrow out of Propose")


def test_an_event_from_a_step_without_arrows_names_only_the_nearest_override() -> None:
    done = reach(*drafted(), Overridden("Done", "shipped"))
    match apply(done, Implemented("a1")):
        case Failure(fix=fix):
            assert fix == 'to record implemented: state override PR "<why>", then rerun'
        case State():
            raise AssertionError("Done has no arrows")


def off_arrow(pair: tuple[State, Event]) -> bool:
    match apply(*pair):
        case Failure(message=message):
            return "is not an arrow" in message
        case State():
            return False


off_arrows = st.tuples(event_lists.map(lambda c: reach(*accepted(c))), events).filter(
    off_arrow
)


@given(off_arrows)
def test_off_arrow_following_the_fix_makes_the_event_an_arrow(
    pair: tuple[State, Event],
) -> None:
    state, event = pair
    refused = apply(state, event)
    assert isinstance(refused, Failure)
    found = OVERRIDE.search(refused.fix)
    assert found is not None
    moved = apply(state, Overridden(found[1], "why"))  # pyright: ignore[reportArgumentType]
    assert isinstance(moved, State)
    match apply(moved, event):
        case Failure(message=again):
            assert "is not an arrow" not in again
        case State():
            pass


# ---- Deciding what to record ----------------------------------------------------------

PARSE_REFUSAL = Failure("state handback implementer: line 1 starts 'done'", "fix", 2)
parsed_results = st.one_of(
    st.lists(events, min_size=1, max_size=3).map(tuple), st.just(PARSE_REFUSAL)
)


@given(event_lists, parsed_results)
def test_decide_every_refusal_appends_one_refused_left_pending_on_the_same_step(
    candidates: list[Event], parsed: tuple[Event, ...] | Failure
) -> None:
    state = reach(*accepted(candidates))

    match decide(state, parsed):
        case Accepted(append=appended, reached=reached):
            assert fold(appended, state) == reached
        case Refusal(refused=refused, reached=reached, reply=reply):
            assert (refused.fix, reply.code) == (reply.fix, 2)
            assert reached == fold((refused,), state)
            assert (reached.refused, reached.step) == (refused, state.step)


@given(event_lists, st.lists(events, min_size=1, max_size=3).map(tuple))
def test_decide_an_accepted_record_appends_what_record_does(
    candidates: list[Event], events_: tuple[Event, ...]
) -> None:
    state = reach(*accepted(candidates))

    decision = decide(state, events_)

    match record(state, events_), decision:
        case Failure(), Refusal():
            pass
        case (appended, reached), Accepted() as taken:
            assert (taken.append, taken.reached) == (appended, reached)
        case other:
            raise AssertionError(other)


def test_decide_stores_a_flow_refusal_bare_and_replies_under_the_command() -> None:
    match decide(S0, (Ready(PR),)):
        case Refusal(refused=Refused(message=stored), reply=Failure(message=said)):
            assert (stored, said) == (
                "'ready' is not an arrow out of Ctx",
                "state record: 'ready' is not an arrow out of Ctx",
            )
        case other:
            raise AssertionError(other)


def test_decide_stores_and_replies_a_parse_refusal_as_it_is() -> None:
    match decide(S0, PARSE_REFUSAL):
        case Refusal(refused=refused, reply=reply):
            assert (refused, reply) == (
                Refused(PARSE_REFUSAL.message, PARSE_REFUSAL.fix),
                PARSE_REFUSAL,
            )
        case other:
            raise AssertionError(other)


def test_warning_tells_the_pending_refusal_and_its_fix() -> None:
    state = reach(Refused("'fixed' is not an arrow out of Refactor", "state show"))

    assert warning(state) == (
        "WARN refused, not recorded: 'fixed' is not an arrow out of Refactor\n"
        "fix: state show\n"
    )


@pytest.mark.parametrize("then", [Researched(1), Overridden("DraftPlan", "why")])
def test_an_accepted_event_or_an_override_clears_the_warning(then: Event) -> None:
    state = reach(Refused("refused", "fix"), then)

    assert warning(state) == ""


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
            "fixer", "READY rows R1, R2 fixed in 5e1f2a9\n\nTouches: auth, interface",
            HandbackOptions(), (Fixed("abc1234", ("auth", "interface")),),
            id="fixer READY with its Touches line",
        ),
        pytest.param(
            "fixer", "READY rows R1 fixed\nTouches: none", HandbackOptions(),
            (Fixed("abc1234", ()),), id="fixer READY touching none",
        ),
        pytest.param(
            "fixer", "READY rows R1 fixed", HandbackOptions(),
            (Fixed("abc1234", ()),), id="fixer READY with no Touches line",
        ),
        pytest.param(
            "fixer", "READY body shortened, 42 visible lines\n\nSimplified: 5e1f2a9",
            HandbackOptions(), (Simplified("5e1f2a9"),),
            id="fixer READY with its Simplified line is S0, no fix",
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
            "implementer", "NEEDS_DECISION which log?", HandbackOptions(),
            (Raised("which log?", "implementer"),),
            id="an untriaged question waits for the lead's triage",
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
            "implementer", "FAILED the test harness is missing", HandbackOptions(),
            (Raised("FAILED the test harness is missing", "implementer"),),
            id="FAILED untriaged",
        ),
        pytest.param(
            "review-lead",
            ("| # | Severity | What |\n|---|---|---|\n| 1 | Blocker | x |\n\n"
            "Reviewed head: 9f8e7d6\n"),
            HandbackOptions(), (Reviewed("9f8e7d6"),), id="review-lead report",
        ),
        pytest.param(
            "review-lead", "READY\n\nReviewed head: 1111111\nReviewed head: 9f8e7d6",
            HandbackOptions(), (Reviewed("9f8e7d6"),),
            id="review-lead: its last Reviewed head line",
        ),
        pytest.param(
            "review-lead",
            ("NEEDS_DECISION plan wrong: the fold cannot see the PR\n\n| table |\n\n"
            "Reviewed head: 9f8e7d6"),
            HandbackOptions(),
            (Reviewed("9f8e7d6"),
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
    assert parse_handback(role, text, options, "abc1234", simplifying=False) == expected  # pyright: ignore[reportArgumentType]


@pytest.mark.parametrize(
    ("role", "text", "head", "fix"),
    [
        pytest.param(
            "review-lead", "| table |", "abc1234",
            "state record reviewed <the head the review read>",
            id="a review without its Reviewed head",
        ),
        pytest.param(
            "fixer", "READY\nTouches: auth, the parser", "abc1234",
            "state record fixed [<head>] [--touches <area>]...",
            id="a Touches line naming no area",
        ),
        pytest.param(
            "fixer", "Done, all green.", "abc1234",
            "record it by hand: state record fixed ...", id="no status token",
        ),
        pytest.param(
            "implementer", "READY", None,
            "run it in the worktree, or state record implemented <sha>", id="no HEAD",
        ),
    ],
)  # fmt: skip
def test_handback_without_what_it_needs_is_a_usage_error(
    role: str, text: str, head: str | None, fix: str
) -> None:
    match parse_handback(role, text, HandbackOptions(), head, simplifying=False):  # pyright: ignore[reportArgumentType]
        case Failure(fix=found, code=code):
            assert (found, code) == (fix, 2)
        case parsed:
            raise AssertionError(f"parsed {parsed}")


def test_a_touches_line_naming_no_area_names_the_words_it_did_not_know() -> None:
    match parse_handback(
        "fixer",
        "READY\nTouches: auth, parser",
        HandbackOptions(),
        "abc1234",
        simplifying=False,
    ):
        case Failure(message=message):
            assert message == (
                "state handback fixer: Touches: names parser, not "
                "interface | data-model | auth"
            )
        case parsed:
            raise AssertionError(f"parsed {parsed}")


def test_an_s0_hand_back_without_its_simplified_line_is_refused_not_a_fix() -> None:
    match parse_handback(
        "fixer",
        "READY body shortened\nTouches: none",
        HandbackOptions(),
        "abc1234",
        simplifying=True,
    ):
        case Failure(fix=fix, code=code):
            assert (fix, code) == (
                "state record simplified <head> once the body is rewritten",
                2,
            )
        case parsed:
            raise AssertionError(f"parsed {parsed}")


# ---- Briefs and views -----------------------------------------------------------------


def test_brief_before_quality_is_recorded_gives_the_default_marked_as_one() -> None:
    state = reach(Started(NOTES, delegated=False))

    lines = brief("researcher", state, "/w").splitlines()

    assert lines[:2] == ["Quality: Balanced (default)", "Size: Normal (default)"]


@pytest.mark.parametrize("role", ["researcher", "reviewer", "checker"])
def test_brief_of_a_non_worker_carries_no_worker_hand_back_rule(role: Role) -> None:
    text = brief(role, reach(*drafted()), "/w")

    assert "READY, NEEDS_DECISION, GREW" not in text


@pytest.mark.parametrize("role", ["refactorer", "review-lead", "fixer"])
def test_brief_of_a_diff_reader_tells_it_to_run_ctx_diff_against_the_base(
    role: Role,
) -> None:
    lines = brief(role, reach(*reviewed()), "/w").splitlines()

    assert (
        "Diff: run ctx diff origin/main, read its index, then the diff ranges" in lines
    )


def test_brief_of_a_diff_reader_before_a_draft_leaves_the_base_to_fill() -> None:
    lines = brief(
        "refactorer", reach(Started(NOTES, delegated=False)), "/w"
    ).splitlines()

    assert (
        "Diff: run ctx diff origin/<base>, read its index, then the diff ranges"
        in lines
    )


@pytest.mark.parametrize("role", ["implementer", "researcher", "reviewer", "checker"])
def test_brief_of_a_role_that_reads_no_diff_has_no_diff_line(role: Role) -> None:
    text = brief(role, reach(*reviewed()), "/w")

    assert "Diff:" not in text


def test_brief_of_a_fixer_asks_for_the_touches_line() -> None:
    text = brief("fixer", reach(*reviewed()), "/w")

    assert (
        "End your hand-back with a line `Touches: <area>...` naming any of "
        "interface, data-model, auth your fix changed (or `Touches: none`)."
    ) in text


@pytest.mark.parametrize(
    "run",
    [final_fixed(), [*final_fixed(), Ci("h4", ())]],
    ids=["DraftPR", "PR at green CI"],
)
def test_brief_of_the_s0_fixer_points_at_pr_descriptions_simplify_section(
    run: list[Event],
) -> None:
    lines = brief("fixer", reach(*run), "/w").splitlines()

    assert "Rows: S0" in lines
    assert any("`## Simplify (row S0)`" in line for line in lines)
    assert not any(
        line.startswith(("R0:", "End your hand-back with a line `Touches:"))
        for line in lines
    )


def test_show_names_the_head_s0_shortened_the_body_on() -> None:
    assert "Simplified: h4\n" in show(reach(*simplified()))


def test_show_before_quality_is_recorded_shows_no_cap() -> None:
    text = show(reach(Started(NOTES, delegated=False), Size("Normal")))

    assert "Quality: <not set>" in text
    assert "Re-review: 0/-   " in text


# ---- The PR on GitHub ---------------------------------------------------------------

prs = st.builds(
    Pr,
    pr_urls,
    st.sampled_from(["main", "parent"]),
    st.sampled_from(["feature", "other"]),
    st.booleans(),
    st.sampled_from(PR_STATES),
)


@given(event_lists, prs)
def test_sync_appends_only_an_event_the_step_takes(
    candidates: list[Event], pr: Pr
) -> None:
    state = reach(*accepted(candidates))

    assert not isinstance(record(state, synced(state, pr)), Failure)


@given(event_lists, prs)
def test_sync_twice_appends_nothing_the_second_time(
    candidates: list[Event], pr: Pr
) -> None:
    state = reach(*accepted(candidates))
    match record(state, synced(state, pr)):
        case Failure() as failure:
            raise AssertionError(failure.message)
        case _, after:
            pass

    assert synced(after, pr) == ()


def test_sync_drafts_a_stacked_pr_with_its_real_base_and_branch() -> None:
    state = reach(*drafted()[:-1])

    found = synced(state, Pr(PR, "parent", "feature", draft=True, state="OPEN"))

    assert found == (Drafted(PR, "parent", "feature"),)


@pytest.mark.parametrize("closed", ["MERGED", "CLOSED"])
def test_sync_drafts_no_merged_or_closed_pr(
    closed: Literal["MERGED", "CLOSED"],
) -> None:
    state = reach(*drafted()[:-1])

    assert synced(state, Pr(PR, "main", "feature", draft=False, state=closed)) == ()


def test_sync_at_pr_records_ready_only_once_the_pr_is_no_draft() -> None:
    state = reach(*final_fixed(), Ci("h4", ()))
    pr = Pr(PR, "main", "feature", draft=True, state="OPEN")

    assert (synced(state, pr), synced(state, replace(pr, draft=False))) == (
        (),
        (Ready(PR),),
    )


@pytest.mark.parametrize(
    ("head", "why"),
    [
        ("other", "HEAD is on other, the run is bound to feature"),
        (None, "HEAD is on no branch, the run is bound to feature"),
    ],
)
def test_a_bound_run_is_off_its_branch_on_another_or_a_detached_head(
    head: str | None, why: str
) -> None:
    assert off_branch(reach(*drafted()), head) == why


def test_a_run_before_its_draft_is_on_any_branch() -> None:
    assert off_branch(reach(*drafted()[:-1]), "other") is None
