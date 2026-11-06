"""Pure: the fold over events, the advice, the hand-back parser, the briefs and
the views. No effect: the shell reads, this decides, the shell writes."""

from collections.abc import Callable, Iterable
from dataclasses import dataclass, replace
from typing import Literal, cast

from flow import (
    FULL_REVIEW,
    HANDBACK_RULE,
    PLAN_WRONG,
    PROPOSALS,
    QUALITY,
    QUALITY_ROWS,
    RE_REVIEWS,
    REFACTOR_ABOVE,
    STATES_FOOTER,
    STATES_INTRO,
    STEPS,
    STOP_RULE,
    TARGET,
    Kind,
    r0_text,
    resume_text,
)
from model import (
    DEFAULT_QUALITY,
    DEFAULT_SIZE,
    DEFAULTS,
    MODES,
    S0,
    TOKENS,
    Adjusted,
    Area,
    Asked,
    Blocked,
    Blocker,
    BlockerKind,
    Ci,
    CiRound,
    Confirmed,
    Defaulted,
    DoneBlocker,
    Drafted,
    Event,
    Failure,
    Fixed,
    Grew,
    Implemented,
    Knob,
    OpenBlocker,
    Overridden,
    Planned,
    Proposed,
    Quality,
    Ready,
    Refactored,
    Researched,
    Resolved,
    Reviewed,
    ReviewRound,
    Role,
    Round,
    Size,
    Started,
    State,
    StateName,
    Verdict,
    Worker,
    mode_of,
    name_of,
    not_met,
    size_of,
)

# ---- Folding ------------------------------------------------------------------


def fold(events: Iterable[Event], state: State = S0) -> State | Failure:
    """`fold(a ++ b) == fold(b, fold(a))`; `fold([]) == S0`."""
    match fold_or_stop(events, state):
        case State() as folded:
            return folded
        case n, failure:
            return replace(failure, message=f"event {n}: {failure.message}")


def fold_or_stop(events: Iterable[Event], state: State) -> State | tuple[int, Failure]:
    """The fold, or the first event off the table: its 1-based position and why."""
    for n, event in enumerate(events, start=1):
        match apply(state, event):
            case Failure() as failure:
                return n, failure
            case State() as state:
                pass
    return state


def apply(state: State, event: Event) -> State | Failure:
    """One arrow: the target from TARGET, or the override's; the data from `absorb`."""
    match event:
        case Overridden(to=to):
            target: StateName | None = to
        case _:
            target = TARGET.get((state.step, classify(state, event)))
    match target, absorb(state, event):
        case None, _:
            return Failure(
                f"'{name_of(event)}' is not an arrow out of {state.step}",
                (
                    f"state next shows {state.step}'s arrows; "
                    f"to leave them, state override <state> <why>"
                ),
                2,
            )
        case _, Failure() as failure:
            return failure
        case _, State() as absorbed:
            return replace(absorbed, step=target)


def classify(state: State, event: Event) -> Kind:  # noqa: PLR0911 - one arm per event
    match event:
        case Started(delegated=True):
            return "started-delegated"
        case Started():
            return "started"
        case Quality() | Size() | Grew() | Defaulted():
            return "knob"
        case Reviewed():
            return "reviewed-loop" if loops(state, event) else "reviewed-final"
        # A delegated run has no Ctx: its decision goes back to the caller.
        case Blocked(kind="decision") if not delegated(state):
            return "blocked-decision"
        case Confirmed() if state.drafted is not None:
            return "confirmed-replan"
        case Blocked():
            return "blocked"
        case (
            Researched() | Asked() | Planned() | Proposed() | Confirmed() | Adjusted()
            | Drafted() | Implemented() | Refactored() | Fixed() | Ci() | Resolved()
            | Ready()
        ):  # fmt: skip
            return cast("Kind", name_of(event))
        case Overridden():
            return "knob"  # never looked up: an override names its own target


def loops(state: State, review: Reviewed) -> bool:
    """A review leads to another fix round while re-reviews remain; a Not met
    verdict gets its fix and one more review even at the cap."""
    return bool(not_met(review.verdicts)) or (
        bool(review.rows) and state.reviews < cap(state)
    )


def cap(state: State) -> int:
    match state.size:
        case "Trivial":
            return 0
        case "Normal" | None:
            return RE_REVIEWS[mode_of(state)]


def absorb(state: State, event: Event) -> State | Failure:  # noqa: C901, PLR0911, PLR0912 - one arm per event
    """The event's data folded into the state; the step is `apply`'s."""
    match event:
        case Started():
            if state.run is not None:
                return Failure("the run has started already", "state show", 2)
            return replace(state, run=event)
        case Quality(mode=mode):
            if state.quality not in (None, mode):
                return Failure(
                    f"Quality is {state.quality} already; it is set once",
                    "a subtask may lower or raise Quality in its own brief",
                    2,
                )
            return replace(state, quality=mode)
        case Size(size=size):
            if state.size not in (None, size):
                return Failure(
                    f"Size is {state.size} already; it is set once and only grows",
                    "state record grew <why>",
                    2,
                )
            return replace(state, size=size)
        case Grew():
            return replace(state, size="Normal")
        case Defaulted(knob=knob):
            return default(state, knob)
        case Researched(n=n):
            return replace(state, researched=state.researched + n)
        case Asked(n=n):
            return replace(state, asked=state.asked + n)
        case Planned(path=path):
            return replace(state, plan=path, proposed=frozenset())
        case Proposed(mode=mode):
            return replace(state, proposed=state.proposed | {mode})
        case Drafted():
            return replace(state, drafted=event)
        case Implemented(head=head) | Refactored(head=head):
            return replace(state, head=head)
        case Reviewed(head=head, rows=rows, verdicts=verdicts):
            return replace(
                state,
                head=head,
                reviews=state.reviews + 1,
                work=event,
                rounds=(*state.rounds, ReviewRound(head, rows, not_met(verdicts))),
            )
        case Fixed(head=head):
            return replace(state, head=head, work=event)
        case Ci(head=head, failing=failing):
            return replace(
                state,
                head=head,
                work=event,
                rounds=(*state.rounds, CiRound(head, failing)),
            )
        case Blocked(question=q, kind=kind, role=role):
            opened = OpenBlocker(q, kind, role)
            # A decision ends the loop's rounds: the stuck guard waits for the
            # next one, so a stuck answered as a decision is no longer stuck.
            work = None if kind == "decision" else state.work
            if any(b.question == q for b in open_blockers(state)):
                blockers = settle(state, q, lambda _: opened)
            else:
                blockers = (*state.blockers, opened)
            return replace(state, blockers=blockers, work=work)
        case Resolved(question=q, answer=answer):
            if not any(b.question == q for b in state.blockers):
                return Failure(
                    f"no blocker asks '{q}'", "state show lists the blockers", 2
                )
            return replace(
                state,
                blockers=settle(state, q, lambda b: DoneBlocker(q, b.kind, answer)),
            )
        case Confirmed():
            # A plan's review starts at round 1: a re-plan resets the cap.
            return replace(state, reviews=0, work=None)
        case Adjusted() | Overridden() | Ready():
            return state


def default(state: State, knob: Knob) -> State | Failure:
    defaulted = (*state.defaulted, knob)
    match knob, state.quality, state.size:
        case "quality", None, _:
            return replace(state, quality=DEFAULT_QUALITY, defaulted=defaulted)
        case "size", _, None:
            return replace(state, size=DEFAULT_SIZE, defaulted=defaulted)
        case "quality", set_to, _:
            return Failure(f"Quality is {set_to} already", "drop this line", 2)
        case "size", _, set_to:
            return Failure(f"Size is {set_to} already", "drop this line", 2)


def settle(
    state: State, question: str, to: Callable[[OpenBlocker], Blocker]
) -> tuple[Blocker, ...]:
    """The blockers with the open one asking `question` replaced by `to` of it."""
    return tuple(
        to(b) if isinstance(b, OpenBlocker) and b.question == question else b
        for b in state.blockers
    )


def open_blockers(state: State) -> list[OpenBlocker]:
    return [b for b in state.blockers if isinstance(b, OpenBlocker)]


# ---- Advice -------------------------------------------------------------------


@dataclass(frozen=True)
class Spawn:
    role: Role
    lines: tuple[str, ...] = ()


@dataclass(frozen=True)
class Ask:
    what: str
    lines: tuple[str, ...] = ()


@dataclass(frozen=True)
class Wait:
    what: str
    lines: tuple[str, ...] = ()


@dataclass(frozen=True)
class Run:
    cmd: str
    lines: tuple[str, ...] = ()


@dataclass(frozen=True)
class Stuck:
    why: str
    lines: tuple[str, ...] = ()


@dataclass(frozen=True)
class Done:
    lines: tuple[str, ...] = ()


type Advice = Spawn | Ask | Wait | Run | Stuck | Done
type SkillChange = Literal["none", "changed", "new"]


@dataclass(frozen=True)
class GitFacts:
    """The branch against `origin/<base>`: changed lines, lockfiles aside, and
    whether a `SKILL.md` is new or changed."""

    lines: int
    skills: SkillChange


@dataclass(frozen=True)
class NoFacts:
    """No base recorded yet, so nothing to diff against."""


type Facts = GitFacts | NoFacts


def advise(state: State, facts: Facts) -> Advice:
    """The next arrow; a delegated run's also names the report it owes."""
    advice = advise_now(state, facts)
    if delegated(state):
        return replace(
            advice,
            lines=(
                *advice.lines,
                "after each step: state show > <the brief's report file>",
            ),
        )
    return advice


def advise_now(state: State, facts: Facts) -> Advice:
    """Stuck first, then an open blocker, then the step's own arrow."""
    match stuck_why(state), first_open(state):
        case str() as why, _:
            return Stuck(why, stuck_lines(state, why))
        case None, OpenBlocker() as blocker:
            return advise_blocker(state, blocker)
        case None, None:
            return advise_step(state, facts)


def stuck_lines(state: State, why: str) -> tuple[str, ...]:
    """The answer is a decision: a lead's takes the decision path, so the
    guard waits for the next round; a delegated run hands it back."""
    if delegated(state):
        return (handback_line(f"NEEDS_DECISION stuck: {why}"),)
    return (
        "ask the user: what changes so the next round differs",
        (
            "the answer is a decision (blockers.md): state record blocked decision "
            f"<role> {quoted(f'stuck: {why}')}, then state record resolved"
        ),
    )


def first_open(state: State) -> OpenBlocker | None:
    """The oldest open blocker other than a lead's decision: that is the
    plan's path through Ctx, so the step's own advice carries it."""
    return next(
        (b for b in open_blockers(state) if b.kind != "decision" or delegated(state)),
        None,
    )


IN_A_ROW = 2  # the stuck guard's "2 rounds in a row"


def stuck_why(state: State) -> str | None:
    """The same row, failing check or question in 2 rounds in a row, whatever
    the commit, while it is still the latest work."""
    reviews = review_rounds(state)
    checks = [r for r in state.rounds if isinstance(r, CiRound)]
    match state.work:
        case Reviewed() if len(reviews) >= IN_A_ROW:
            same = labels(reviews[-2]) & labels(reviews[-1])
            if same:
                return f"row {', '.join(sorted(same))} in 2 rounds in a row"
        case Ci() if len(checks) >= IN_A_ROW:
            same = set(checks[-2].failing) & set(checks[-1].failing)
            if same:
                return f"check {', '.join(sorted(same))} failing in 2 rounds in a row"
        case _:
            pass
    asked = [b.question for b in state.blockers]
    if (
        len(asked) >= IN_A_ROW
        and asked[-1] == asked[-2]
        and any(b.question == asked[-1] for b in open_blockers(state))
    ):
        return f"question '{asked[-1]}' back in 2 rounds in a row"
    return None


def review_rounds(state: State) -> list[ReviewRound]:
    return [r for r in state.rounds if isinstance(r, ReviewRound)]


def labels(review: ReviewRound) -> set[str]:
    return set(review.rows) | {f"not met: {r}" for r in review.not_met}


def advise_blocker(state: State, blocker: OpenBlocker) -> Advice:
    q = blocker.question
    resolve = f"then: state record resolved {quoted(q)} <answer>"
    match blocker.kind:
        case "answered":
            return Spawn(
                blocker.role,
                (
                    (
                        f"a fresh {blocker.role}: state brief {blocker.role}, plus the answer to "
                        f"{quoted(q)} and the delta plan when there is one"
                    ),
                    resume_text(state.head or "<sha>"),
                    resolve,
                ),
            )
        case "fact":
            return Spawn(
                "researcher",
                (
                    (
                        f"one researcher for {quoted(q)}, prompt per the researcher skill's "
                        "## Callers; it does not count against step 1"
                    ),
                    "then a delta plan"
                    + ("" if state.size == "Trivial" else ", its simplify pass")
                    + ", the fact and the delta in the PR body, and resume",
                    resolve,
                ),
            )
        case "decision" | "scope" if delegated(state):
            return Done(
                (
                    handback_line(f"NEEDS_DECISION {q}"),
                    f"resumed with the answer: {resolve[6:]}, then state next",
                )
            )
        case "scope":
            return Ask(
                "scope",
                (
                    f"one AskUserQuestion on {quoted(q)}: in this PR, a follow-up, or drop",
                    (
                        "in this PR: state record blocked decision "
                        f"{blocker.role} {quoted(q)}"
                    ),
                    "a follow-up: add it to ## Follow-ups; either way: " + resolve[6:],
                ),
            )
        case "decision":
            return advise_step(state, NoFacts())


def advise_step(state: State, facts: Facts) -> Advice:  # noqa: C901, PLR0911 - one arm per state
    match state.step:
        case "Ctx":
            return advise_ctx(state)
        case "Prop":
            return advise_prop(state)
        case "DraftPlan":
            return advise_draft(state)
        case "Impl":
            return advise_impl(state)
        case "Impl'":
            return advise_refactor(state, facts)
        case "ImplR":
            return first_review(state, facts, ())
        case "Impl''":
            return advise_rounds(state, facts)
        case "DraftPR":
            return advise_final(state)
        case "PR":
            return advise_pr(state)
        case "Done":
            return Done(("the PR is ready; the user runs the next steps",))


def advise_ctx(state: State) -> Advice:
    decisions = [b for b in open_blockers(state) if b.kind == "decision"]
    if state.size is None:
        return Run(
            "state record size Trivial|Normal",
            ("before step 1, from the prompt and at most 5 lookups: the Trivial rule",),
        )
    mode = mode_of(state)
    researchers = (
        "Trivial: none, at most 5 lookups by you"
        if state.size == "Trivial"
        else f"at least 1, typically 2-3; {mode}: {QUALITY['Researchers'][mode]}"
    )
    counts = (
        *(f"decision path for {quoted(b.question)}" for b in decisions),
        f"researchers {state.researched} ({researchers})",
        f"questions {state.asked} (at least 1, typically 4-12)",
        "each: state record researched | state record asked",
    )
    # The plan states its Quality, so a lead's run picks it before the plan.
    if state.quality is None and not delegated(state):
        return Ask(
            "quality",
            (
                "research and ask on demand, any order; when nothing is open, before plan.md:",
                "one AskUserQuestion: POC, Balanced (Recommended), Max, unless the prompt sets it",
                "then: state record quality <mode>",
                *counts,
            ),
        )
    return Run(
        f"state record planned {notes_of(state)}/plan.md",
        (
            "research and ask on demand, any order; when nothing is open, write the plan",
            *counts,
        ),
    )


def advise_prop(state: State) -> Advice:
    if state.size == "Trivial":
        return Run(
            "state record confirmed",
            ("Trivial: no proposals and no confirm question; the plan is a few lines",),
        )
    if state.quality is None:
        return Ask(
            "quality", ("one AskUserQuestion: POC, Balanced (Recommended), Max",)
        )
    mode = state.quality
    missing = [m for m in PROPOSALS[mode] if m not in state.proposed]
    if missing:
        return Spawn(
            "researcher",
            (
                "background; the prompt names the researcher skill's references/proposal.md",
                f"modes: {', '.join(missing)}  Quality: {mode}",
                f"plan: {state.plan}  notes: {notes_of(state)}",
                "after an adjust that kept the approach: skip to the ask",
                "each mode back: state record proposed <mode>",
            ),
        )
    options = (
        '"Yes, build it (Recommended)" / "No, adjust"'
        if mode == "POC"
        else (
            '"First plan", "Second plan", "Adjust", the recommended first, '
            "marked (Recommended); no proposal-alternative.md: "
            '"Yes, build it (Recommended)" / "No, adjust"'
        )
    )
    return Ask(
        "plan",
        (
            "the first plan in a few lines, the second with its trade-off, your pick",
            f"one AskUserQuestion: {options}",
            *(
                [
                    (
                        f"picked, a re-plan: gh pr edit {pr_ref(state)} --body-file <the chosen "
                        "plan with its Considered options>; it resumes at 5 on the same branch"
                    )
                ]
                if state.drafted is not None
                else []
            ),
            "picked: state record confirmed; adjust: state record adjusted",
        ),
    )


def advise_draft(state: State) -> Advice:
    if delegated(state) and (state.quality is None or state.size is None):
        knob = "quality" if state.quality is None else "size"
        return Run(
            f"state record {knob} <your brief's {knob.capitalize()}: line>",
            ("delegated: the brief sets both knobs",),
        )
    record = "then: state record drafted <the PR URL gh printed> <base>"
    knobs = f"Quality: {knob_text(state, 'quality')}  Size: {knob_text(state, 'size')}"
    poc = state.quality == "POC"
    if delegated(state):
        return Run(
            "gh pr create --draft --repo <repo> --head <branch> --base <base>",
            (
                "the worktree exists: no branching; no attach",
                f"body: the brief's plan, {knobs}, acceptance criteria",
                *(
                    [
                        "POC: gh label create POC --force --repo <repo>",
                        "     gh pr edit <n> --add-label POC --repo <repo>",
                    ]
                    if poc
                    else []
                ),
                record,
            ),
        )
    return Run(
        "gh pr create --draft",
        (
            (
                "before: branch from origin/main, the first commit (or an empty one), "
                "git push -u origin HEAD"
            ),
            "body: the plan"
            + (" in the pr-description short form" if state.size == "Trivial" else "")
            + f", {knobs}, acceptance criteria,",
            "      Security-sensitive: <ci, auth, database, secrets> when it touches one",
            "then attach the PR to the session as your instructions say",
            *(
                [
                    "POC: gh label create POC --force",
                    "     gh pr edit <n> --add-label POC",
                ]
                if poc
                else []
            ),
            record,
        ),
    )


def advise_impl(state: State) -> Advice:
    mode = mode_of(state)
    how = (
        "Trivial: one implementer; a bug fix comes with a test red before it"
        if state.size == "Trivial"
        else f"{mode}: {QUALITY['Implement'][mode]}"
    )
    return Spawn(
        "implementer",
        (
            "brief: state brief implementer, plus its slice",
            how,
            "slices one after another; in parallel only when independent",
            "a hand-back at the context warning: a successor with "
            + resume_text("<its commit>"),
            "READY: state handback implementer < text",
        ),
    )


def advise_refactor(state: State, facts: Facts) -> Advice:
    mode = mode_of(state)
    match state.size, mode, facts:
        case "Trivial", _, _:
            return first_review(state, facts, ("refactor skipped: Trivial",))
        case _, "Balanced", GitFacts(lines=lines) if lines <= REFACTOR_ABOVE:
            return first_review(
                state, facts, (f"refactor skipped: {lines} changed lines, Balanced",)
            )
        case _:
            unknown = (
                ("changed lines unknown: no base recorded",)
                if isinstance(facts, NoFacts)
                else ()
            )
            return Spawn(
                "refactorer",
                (
                    *unknown,
                    f"brief: state brief refactorer; {mode}: {QUALITY['Refactor'][mode]}",
                    "proposals: one AskUserQuestion each, in this PR / a follow-up / drop",
                    "READY: state handback refactorer < text",
                ),
            )


def first_review(state: State, facts: Facts, before: tuple[str, ...]) -> Spawn:
    requirements = (
        "the brief's requirements file"
        if delegated(state)
        else f"{notes_of(state)}/requirements.md"
    )
    return Spawn(
        "review-lead",
        (
            *before,
            f"first: {requirements}, once per plan (review.md Requirements)",
            *dry_run(state, facts),
            "brief: state brief review-lead",
            review_args(state),
            (
                "back: state handback review-lead [--row <label>]... "
                "[--verdict <requirement>=not-met]... < text"
            ),
        ),
    )


def dry_run(state: State, facts: Facts) -> tuple[str, ...]:  # noqa: PLR0911 - one arm per row cell
    spawn = (
        "also: SPAWN reviewer, a dry run of the changed SKILL.md in parallel: "
        "state brief reviewer"
    )
    match state.size, mode_of(state), facts:
        case "Trivial", _, _:
            return ()
        case _, "POC", _:
            return ()
        case _, "Balanced", GitFacts(skills="new"):
            return (spawn,)
        case _, "Balanced", GitFacts(skills="changed"):
            return ("a SKILL.md changed: a dry run only if it is rewritten",)
        case _, "Max", GitFacts(skills="new" | "changed"):
            return (spawn,)
        case _, _, NoFacts():
            return ("a SKILL.md in the diff: a dry run as your Quality row says",)
        case _:
            return ()


def advise_rounds(state: State, facts: Facts) -> Advice:
    match state.work:
        case Reviewed(rows=rows, verdicts=verdicts):
            at_cap = state.reviews > cap(state)
            return Spawn(
                "fixer",
                (
                    f"rows: {', '.join(rows) or '-'}",
                    *(
                        [
                            (
                                f"at the cap: fix only Not met {', '.join(not_met(verdicts))}; "
                                "the other rows go to the final fixer"
                            )
                        ]
                        if at_cap
                        else []
                    ),
                    "brief: state brief fixer",
                    "READY: state handback fixer [--touches <area>]... < text",
                ),
            )
        case Fixed(touches=touches) if wide(state, touches):
            return Spawn(
                "review-lead",
                (
                    (
                        f"a fix to {', '.join(touches)}: a first review of the whole branch, "
                        "a round"
                    ),
                    f"round {state.reviews}/{cap(state)}",
                    "brief: state brief review-lead",
                    review_args(state),
                ),
            )
        case Fixed():
            return Spawn(
                "review-lead",
                (
                    (
                        f"first: {fixes_copy(state)}, copied once from the requirements; "
                        "append 'finding N is fixed: <What and Impact>' per fixed row"
                    ),
                    f"round {state.reviews}/{cap(state)}",
                    "brief: state brief review-lead",
                    review_args(state),
                ),
            )
        case Ci() | None:
            return first_review(state, facts, ())


def advise_final(state: State) -> Advice:
    match state.work:
        case Fixed() if delegated(state):
            return Done(
                (
                    handback_line(f"READY {pr_ref(state)}"),
                    (
                        "with the last finished step, the head sha and the full check's "
                        "name when one is owed"
                    ),
                ),
            )
        case Fixed():
            return Wait(
                "ci",
                (
                    "notify: the draft is complete and CI runs",
                    "a full check owed and not run by the fixer: SPAWN checker",
                    "each CI result: state record ci [--failing <check>]...",
                ),
            )
        case Reviewed(rows=rows):
            return final_fixer(state, rows)
        case Ci() | None:
            return final_fixer(state, ())


def final_fixer(state: State, rows: tuple[str, ...]) -> Spawn:
    return Spawn(
        "fixer",
        (
            f"final fixer: rows {', '.join([*rows, 'R0'])}; nothing reviews it",
            r0_text(base_of(state)),
            "the full check before its push when one is owed",
            "brief: state brief fixer",
            "READY: state handback fixer < text",
        ),
    )


def advise_pr(state: State) -> Advice:  # noqa: PLR0911 - one arm per loop step
    left = cap(state) - max(state.reviews - 1, 0)
    match state.work:
        case Ci(failing=()) if state.quality == "POC":
            return Done(
                ("notify: CI is green; the PR stays a labelled draft, no next steps",)
            )
        case Ci(failing=()):
            pr = pr_ref(state)
            return Run(
                f"gh pr ready {pr}",
                (
                    (
                        "before: every review comment replied or triaged, every open "
                        "decision triaged"
                    ),
                    (
                        "a workflow in the diff: each secrets.* in gh secret list "
                        "[--env <env> | --org <owner>]"
                    ),
                    (
                        f"notify, with: /qa {pr}  /final-review --requirements "
                        f"{notes_of(state)}/requirements.md {pr}"
                    ),
                    f"  /give-feedback {pr}  /address-pr-feedback {pr} (comments from others)",
                    f"then: state record ready {pr}",
                ),
            )
        case Ci(failing=failing):
            return Spawn(
                "fixer",
                (
                    f"CI fix: {', '.join(failing)}",
                    f"plus {r0_text(base_of(state))}, when the fix changes what the body says",
                    "brief: state brief fixer",
                    "READY: state handback fixer < text",
                ),
            )
        case Fixed() if left > 0 and state.size != "Trivial":
            return Spawn(
                "review-lead",
                (
                    f"round {state.reviews}/{cap(state)}: a --fixes review of the CI fix",
                    "brief: state brief review-lead",
                    review_args(state),
                ),
            )
        case Reviewed(rows=rows) if rows and left > 0:
            return Spawn(
                "fixer", (f"rows: {', '.join(rows)}", "brief: state brief fixer")
            )
        case Reviewed(rows=rows) if rows:
            return final_fixer(state, rows)
        case Fixed() | Reviewed() | None:
            return wait_ci(state)


def wait_ci(state: State) -> Wait:
    return Wait(
        "ci",
        (
            f"on a CI wake on the head commit: gh pr checks {pr_ref(state)}, once",
            "then: state record ci [--failing <check>]...",
        ),
    )


def wide(state: State, touches: tuple[Area, ...]) -> bool:
    return bool(FULL_REVIEW[mode_of(state)] & set(touches))


def review_args(state: State) -> str:
    """The review-lead's invoke line: a whole-branch review, or `--fixes` the
    previous round's Reviewed head with the fixes copy."""
    head = f"Quality: {mode_of(state)} Size: {size_of(state)}"
    pr = pr_ref(state)
    reviewed = [r.head for r in review_rounds(state)]
    match state.work:
        case Fixed(touches=touches) if reviewed and not wide(state, touches):
            return (
                f"invoke `pragmatic-review` with: {head} --fixes {reviewed[-1]} "
                f"--requirements {fixes_copy(state)} {pr}"
            )
        case _:
            return (
                f"invoke `pragmatic-review` with: {head} --requirements "
                f"{requirements_of(state)} {pr}"
            )


def requirements_of(state: State) -> str:
    return (
        "<the brief's requirements file>"
        if delegated(state)
        else f"{notes_of(state)}/requirements.md"
    )


def fixes_copy(state: State) -> str:
    return (
        "<the brief's requirements file's directory>/<the brief's task>-fixes.md"
        if delegated(state)
        else f"{notes_of(state)}/requirements-fixes.md"
    )


def handback_line(status: str) -> str:
    return f"hand back: {status}, the work pushed"


def delegated(state: State) -> bool:
    return state.run is not None and state.run.delegated


def notes_of(state: State) -> str:
    return state.run.notes if state.run is not None else "<notes>"


def base_of(state: State) -> str:
    return state.drafted.base if state.drafted is not None else "<base>"


def pr_ref(state: State) -> str:
    return state.drafted.url if state.drafted is not None else "<pr-url>"


def knob_text(state: State, knob: Knob) -> str:
    value = state.quality if knob == "quality" else state.size
    return value or f"{DEFAULTS[knob]} (defaulted when drafted)"


def quoted(text: str) -> str:
    return "'" + text.replace("'", "'\\''") + "'"


def render_advice(advice: Advice) -> str:
    match advice:
        case Spawn(role=role, lines=lines):
            first = f"SPAWN {role}"
        case Ask(what=what, lines=lines):
            first = f"ASK {what}"
        case Wait(what=what, lines=lines):
            first = f"WAIT {what}"
        case Run(cmd=cmd, lines=lines):
            first = f"RUN {cmd}"
        case Stuck(why=why, lines=lines):
            first = f"STUCK {why}"
        case Done(lines=lines):
            first = "DONE"
    return "".join(f"{line}\n" for line in (first, *(f"  {line}" for line in lines)))


# ---- Recording ----------------------------------------------------------------


def record(
    state: State, events: tuple[Event, ...]
) -> tuple[tuple[Event, ...], State] | Failure:
    """What to append for `events`, and the state it reaches: a draft PR first
    records each knob nobody set, at its default, so replay shows it."""
    values: tuple[tuple[Knob, str | None], ...] = (
        ("quality", state.quality),
        ("size", state.size),
    )
    knobs = tuple(Defaulted(knob) for knob, value in values if value is None)
    appended = tuple(
        e
        for event in events
        for e in ((*knobs, event) if isinstance(event, Drafted) else (event,))
    )
    match fold_or_stop(appended, state):
        case State() as reached:
            return appended, reached
        case _, failure:
            return failure


# ---- Hand-backs ---------------------------------------------------------------


@dataclass(frozen=True)
class HandbackOptions:
    kind: BlockerKind | None = None
    touches: tuple[Area, ...] = ()
    rows: tuple[str, ...] = ()
    verdicts: tuple[Verdict, ...] = ()


def parse_handback(  # noqa: PLR0911 - one arm per status
    role: Worker, text: str, options: HandbackOptions, head: str | None
) -> tuple[Event, ...] | Failure:
    """A worker's first line is its status; a review-lead's report ends with
    `Reviewed head: <sha>` and may start with a plan-wrong line."""
    lines = [line.strip() for line in text.strip().splitlines()]
    first = lines[0] if lines else ""
    token, _, rest = first.partition(" ")
    reviewed = reviewed_head(lines)
    match role, token:
        case _, "NEEDS_DECISION":
            grew = tuple(
                Grew(line.removeprefix("GREW ").strip())
                for line in lines[1:2]
                if line.startswith("GREW ")
            )
            review: tuple[Event, ...] = (
                (Reviewed(reviewed, (), ()),)
                if role == "review-lead" and reviewed is not None
                else ()
            )
            match triage(rest, options.kind):
                case Failure() as failure:
                    return failure
                case kind:
                    return (*review, Blocked(rest, kind, role), *grew)
        case _, "GREW":
            return (Grew(rest),)
        case _, "BLOCKED" | "FAILED":
            match triage(first, options.kind):
                case Failure() as failure:
                    return failure
                case kind:
                    return (Blocked(first, kind, role),)
        case "review-lead", _:
            if reviewed is None:
                return Failure(
                    "state handback review-lead: no 'Reviewed head: <sha>' line",
                    "state record reviewed <sha> [--row <label>]... by hand",
                    2,
                )
            return (Reviewed(reviewed, options.rows, options.verdicts),)
        case _, "READY":
            return ready(role, head, options.touches)
        case _:
            return Failure(
                f"state handback {role}: line 1 starts '{token}', not one of "
                + " | ".join(TOKENS),
                f"record it by hand: state record {role_event(role)} ...",
                2,
            )


def ready(
    role: Literal["implementer", "refactorer", "fixer"],
    head: str | None,
    touches: tuple[Area, ...],
) -> tuple[Event, ...] | Failure:
    match role, head:
        case _, None:
            return Failure(
                f"state handback {role}: no HEAD to record",
                f"run it in the worktree, or state record {role_event(role)} <sha>",
                2,
            )
        case "implementer", str():
            return (Implemented(head),)
        case "refactorer", str():
            return (Refactored(head),)
        case "fixer", str():
            return (Fixed(head, touches),)


def role_event(role: Worker) -> str:
    match role:
        case "implementer":
            return "implemented"
        case "refactorer":
            return "refactored"
        case "fixer":
            return "fixed"
        case "review-lead":
            return "reviewed"


def reviewed_head(lines: list[str]) -> str | None:
    found = [line for line in lines if line.startswith("Reviewed head:")]
    return found[-1].removeprefix("Reviewed head:").strip() or None if found else None


def triage(question: str, kind: BlockerKind | None) -> BlockerKind | Failure:
    """A plan-wrong or stuck line is a decision; any other question is the
    lead's triage, passed as --kind."""
    match kind:
        case None if question.startswith(("plan wrong:", "stuck:")):
            return "decision"
        case None:
            return Failure(
                f"state handback: triage '{question}' first",
                "add --kind answered|fact|decision|scope (blockers.md, Triage)",
                2,
            )
        case _:
            return kind


# ---- Briefs -------------------------------------------------------------------


def brief(role: Role, state: State, worktree: str) -> str:
    """The mechanical part of a spawn prompt; the lead fills the `<...>` lines."""
    # Before a knob is recorded a worker gets its default, marked as one.
    mode = state.quality or f"{DEFAULT_QUALITY} (default)"
    size = state.size or f"{DEFAULT_SIZE} (default)"
    base = base_of(state)
    match role:
        case "refactorer":
            first, tail = (
                f"run `refactor` with: Quality: {mode}",
                [STOP_RULE, HANDBACK_RULE],
            )
        case "implementer" | "fixer":
            first, tail = f"Quality: {mode}", [STOP_RULE, HANDBACK_RULE]
        case "review-lead":
            args = review_args(state).split(": ", 1)[1]
            first, tail = f"invoke `pragmatic-review` with: {args}", [PLAN_WRONG]
        case "reviewer" | "researcher" | "checker":
            # Their role or skill sets their hand-back: a report, notes, PASS or FAIL.
            first, tail = f"Quality: {mode}", []
    head = [
        *(["<the first line of your spawn prompt>"] if delegated(state) else []),
        first,
        f"Size: {size}",
        f"Worktree: {worktree} (every command runs here)",
        f"Base: origin/{base}",
        f"Plan: {state.plan or '<plan path>'}",
    ]
    body = role_lines(role, state)
    return "".join(
        f"{line}\n" for line in (*head, *body, *([""] if tail else []), *tail)
    )


def role_lines(role: Role, state: State) -> list[str]:  # noqa: C901, PLR0911 - one arm per role
    base = base_of(state)
    match role:
        case "implementer":
            return [
                "Slice: <the slice>",
                f"Research notes: <paths under {notes_of(state)} and the sections it needs>",
                "Targeted checks only, never the full check: <the checks>",
                "The previous slice started at <sha>, when there is one.",
            ]
        case "refactorer":
            return []
        case "fixer":
            match state.step, state.work:
                case "DraftPR", Reviewed(rows=rows) | Ci(failing=rows):
                    rows_line = f"Rows: {', '.join([*rows, 'R0'])}"
                case "DraftPR", _:
                    rows_line = "Rows: R0"
                case _, Reviewed(rows=rows) | Ci(failing=rows) if rows:
                    rows_line = f"Rows: {', '.join(rows)}"
                case _:
                    rows_line = "Rows: <the chosen rows>"
            final = [
                r0_text(base),
                "Run the full check before the push: <check>, when one is owed.",
            ]
            return [
                rows_line,
                *(final if state.step == "DraftPR" else []),
                f"A row that needs the branch's changes: ctx diff origin/{base}",
                "Targeted checks only: <the checks>",
            ]
        case "review-lead":
            return (
                ["No children: the Trivial sweep."] if state.size == "Trivial" else []
            )
        case "reviewer":
            return [
                "Dry run: read the changed SKILL.md from the branch, not the installed copy,",
                "follow it step by step on <a realistic task>, with no push or other outside",
                "effect, and report each step you could not follow or that misled you.",
            ]
        case "researcher":
            return [
                "Topic: <the topic>",
                f"notes: {notes_of(state)}/research-<topic>",
                "roots: <worktree or clone paths, URLs>",
                "questions: <each with the decision it feeds>",
                "known: <facts already settled, earlier notes paths>",
            ]
        case "checker":
            return [
                "Run: <the check>",
                "Hand back PASS, or FAIL with each failing check.",
            ]


# ---- Views --------------------------------------------------------------------


def render() -> str:
    """The skill's `## States` block, a blank line, then the engineer's
    Quality rows, each a line of `quality.md`."""
    rows = "".join(f"| {step} | {name} | {arrows} |\n" for step, name, arrows in STEPS)
    quality = "".join(
        f"| {name} | {' | '.join(cells[m] for m in MODES)} |\n"
        for name, cells in QUALITY_ROWS
    )
    return (
        f"## States\n\n{STATES_INTRO}\n\n| Step | State | Arrows out |\n|---|---|---|\n"
        f"{rows}\n{STATES_FOOTER}\n\n{quality}"
    )


def show(state: State) -> str:
    def knob(name: Knob, value: str | None) -> str:
        return (
            f"{value} (defaulted)" if name in state.defaulted else value or "<not set>"
        )

    reviewed = [r.head for r in review_rounds(state)]
    rounds = [round_line(i, r) for i, r in enumerate(state.rounds, start=1)]
    blockers = [
        f"- {b.question} - {b.kind} - open"
        if isinstance(b, OpenBlocker)
        else f"- {b.question} - {b.kind} - done: {b.answer}"
        for b in state.blockers
    ]
    lines = [
        f"Step: {state.step}",
        f"Head: {state.head or '-'}",
        f"Quality: {knob('quality', state.quality)}",
        f"Size: {knob('size', state.size)}",
        (
            f"Re-review: {max(state.reviews - 1, 0)}/"
            f"{cap(state) if state.quality or state.size == 'Trivial' else '-'}   "
            "(round 1 is the first review, not counted)"
        ),
        f"Reviewed head: {reviewed[-1] if reviewed else '-'}",
        (
            f"Notes: {notes_of(state)}  Plan: {state.plan or '-'}  "
            f"PR: {pr_ref(state)}  Base: {base_of(state)}"
        ),
        f"Researched: {state.researched}  Asked: {state.asked}",
        "Rounds:",
        *rounds,
        "Blockers:",
        *blockers,
    ]
    return "".join(f"{line}\n" for line in lines)


def round_line(n: int, r: Round) -> str:
    match r:
        case ReviewRound(head=head, rows=rows, not_met=not_met):
            failing = ", ".join([*rows, *(f"not met: {x}" for x in not_met)])
            return f"- review {n} - {head} - {failing or 'no rows'}"
        case CiRound(head=head, failing=failing):
            return f"- ci {n} - {head} - {', '.join(failing) or 'green'}"
