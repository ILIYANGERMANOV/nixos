"""`state`: record the engineer flow as events and advise the next arrow.

The only stored thing is `events.jsonl` in the run's notes directory, an
append-only JSON Lines log (https://jsonlines.org/). The current state is a
left fold over it, and the advice is a pure function of that state and the few
git facts the shell reads. It advises, never refuses: `state override` is the
way off an arrow. ADR 0014 holds the principles, ADR 0015 this program.
Stdlib only.
"""

import json
import os
import subprocess
import sys
from collections.abc import Callable, Iterable, Sequence
from dataclasses import dataclass, fields, replace
from datetime import UTC, datetime
from pathlib import Path
from typing import Literal, Protocol, cast

# ---- Vocabulary ---------------------------------------------------------------

type StateName = Literal[
    "Ctx",
    "Prop",
    "DraftPlan",
    "Impl",
    "Impl'",
    "ImplR",
    "Impl''",
    "DraftPR",
    "PR",
    "Done",
]
type Mode = Literal["POC", "Balanced", "Max"]
type SizeName = Literal["Trivial", "Normal"]
type Knob = Literal["quality", "size"]
type ProposalMode = Literal["simplify", "alternative"]
type BlockerKind = Literal["answered", "fact", "decision", "scope"]
type Area = Literal["data-model", "auth", "interface"]
type Outcome = Literal["met", "not-met", "unverified"]
type Role = Literal[
    "implementer",
    "refactorer",
    "fixer",
    "review-lead",
    "reviewer",
    "researcher",
    "checker",
]
type Worker = Literal["implementer", "refactorer", "fixer", "review-lead"]

STATES: tuple[StateName, ...] = (
    "Ctx", "Prop", "DraftPlan", "Impl", "Impl'", "ImplR", "Impl''", "DraftPR", "PR", "Done",
)  # fmt: skip
MODES: tuple[Mode, ...] = ("POC", "Balanced", "Max")
SIZES: tuple[SizeName, ...] = ("Trivial", "Normal")
PROPOSAL_MODES: tuple[ProposalMode, ...] = ("simplify", "alternative")
BLOCKER_KINDS: tuple[BlockerKind, ...] = ("answered", "fact", "decision", "scope")
AREAS: tuple[Area, ...] = ("data-model", "auth", "interface")
OUTCOMES: tuple[Outcome, ...] = ("met", "not-met", "unverified")
ROLES: tuple[Role, ...] = (
    "implementer", "refactorer", "fixer", "review-lead", "reviewer", "researcher", "checker",
)  # fmt: skip
WORKERS: tuple[Worker, ...] = ("implementer", "refactorer", "fixer", "review-lead")
KNOBS: tuple[Knob, ...] = ("quality", "size")
DEFAULT_QUALITY: Mode = "Balanced"
DEFAULT_SIZE: SizeName = "Normal"
DEFAULTS: dict[Knob, str] = {"quality": DEFAULT_QUALITY, "size": DEFAULT_SIZE}
TOKENS = ("READY", "NEEDS_DECISION", "GREW", "BLOCKED", "FAILED")

# What `json.loads` can return, spelled out because typeshed says Any.
type Json = None | bool | int | float | str | list[Json] | dict[str, Json]

# ---- Events -------------------------------------------------------------------


@dataclass(frozen=True)
class Started:
    notes: str
    delegated: bool


@dataclass(frozen=True)
class Quality:
    mode: Mode


@dataclass(frozen=True)
class Size:
    size: SizeName


@dataclass(frozen=True)
class Grew:
    why: str


@dataclass(frozen=True)
class Defaulted:
    """A knob nobody set by the time the draft PR opened, at its default."""

    knob: Knob


@dataclass(frozen=True)
class Researched:
    n: int


@dataclass(frozen=True)
class Asked:
    n: int


@dataclass(frozen=True)
class Planned:
    path: str


@dataclass(frozen=True)
class Proposed:
    mode: ProposalMode


@dataclass(frozen=True)
class Confirmed:
    pass


@dataclass(frozen=True)
class Adjusted:
    pass


@dataclass(frozen=True)
class Drafted:
    pr: int
    base: str


@dataclass(frozen=True)
class Implemented:
    head: str


@dataclass(frozen=True)
class Refactored:
    head: str


@dataclass(frozen=True)
class Verdict:
    requirement: str
    outcome: Outcome


@dataclass(frozen=True)
class Reviewed:
    """A review's return: its `Reviewed head`, the rows the lead chose to fix,
    labelled so the same finding keeps its label across rounds, and verdicts."""

    head: str
    rows: tuple[str, ...]
    verdicts: tuple[Verdict, ...]


@dataclass(frozen=True)
class Fixed:
    head: str
    touches: tuple[Area, ...]


@dataclass(frozen=True)
class Ci:
    """A CI result on `head`; no failing check is green."""

    head: str
    failing: tuple[str, ...]


@dataclass(frozen=True)
class Blocked:
    """A worker's question, triaged. The same open question again re-triages it."""

    question: str
    kind: BlockerKind
    role: Role


@dataclass(frozen=True)
class Resolved:
    question: str
    answer: str


@dataclass(frozen=True)
class Overridden:
    to: StateName
    why: str


@dataclass(frozen=True)
class Ready:
    pr: int


type Event = (
    Started | Quality | Size | Grew | Defaulted | Researched | Asked | Planned | Proposed
    | Confirmed | Adjusted | Drafted | Implemented | Refactored | Reviewed | Fixed | Ci
    | Blocked | Resolved | Overridden | Ready
)  # fmt: skip

# ---- The event table ----------------------------------------------------------

# Each event is described once below: its fields, read in its command-line
# order, each with its Codec. Three readers interpret that description: JSON
# (the log, both ways), the command line (`state record`) and the usage (HELP).


class BadFieldError(Exception):
    """A field that is not what its event says; caught where it is read."""


@dataclass(frozen=True)
class Codec[T]:
    """A field type: read from JSON, parsed from an argument, shown in usage."""

    decode: Callable[[str, Json], T]
    parse: Callable[[str, str], T]
    shown: str | None  # the usage word; None shows `<name>`
    sample: T  # any valid value: what the usage reader returns


@dataclass(frozen=True)
class Option[T]:
    """A field given as repeated `--flag <meta>` options; a JSON list."""

    name: str
    flag: str
    meta: str
    codec: Codec[T]


class Fields(Protocol):
    def one[T](self, name: str, codec: Codec[T]) -> T: ...

    def optional[T](self, name: str, codec: Codec[T], default: T) -> T: ...

    def head(self) -> str:
        """The commit a field names; left out on the command line, HEAD."""
        ...

    def many[T](self, option: Option[T]) -> tuple[T, ...]: ...

    def constant(self, name: str, value: Json) -> None:
        """A JSON-only field derived from the others, kept so a reader sees it."""
        ...


@dataclass(frozen=True)
class Spec:
    read: Callable[[Fields], Event]
    # False: another command writes it (`init`, a draft PR's defaults, `override`).
    recordable: bool = True


def a_text(key: str, value: Json) -> str:
    if not isinstance(value, str) or not value.strip():
        raise BadFieldError(f"{key} is not a non-empty string")
    return value


def a_count(key: str, value: Json) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 1:
        raise BadFieldError(f"{key} is not a positive integer")
    return value


def parse_count(key: str, value: str) -> int:
    return a_count(key, int(value) if value.isdigit() else None)


def a_flag(key: str, value: Json) -> bool:
    if not isinstance(value, bool):
        raise BadFieldError(f"{key} is not true or false")
    return value


def choice[L: str](choices: tuple[L, ...], *, listed: bool = True) -> Codec[L]:
    def one_of(key: str, value: Json) -> L:
        match pick(a_text(key, value), choices):
            case None:
                raise BadFieldError(
                    f"{key} '{value}' is not one of {', '.join(choices)}"
                )
            case found:
                return found

    return Codec(one_of, one_of, "|".join(choices) if listed else None, choices[0])


def pick[L: str](value: str, choices: Sequence[L]) -> L | None:
    return next((c for c in choices if c == value), None)


def a_verdict(key: str, value: Json) -> Verdict:
    obj = an_object(value, f"a {key} item")
    return Verdict(
        a_text("requirement", obj.get("requirement")),
        OUTCOME.decode("outcome", obj.get("outcome")),
    )


def parse_verdict(_key: str, value: str) -> Verdict:
    requirement, _, outcome = value.rpartition("=")
    return Verdict(
        a_text("requirement", requirement), OUTCOME.parse("outcome", outcome)
    )


def an_object(value: Json, what: str) -> dict[str, Json]:
    if not isinstance(value, dict):
        raise BadFieldError(f"{what} is not a JSON object")
    return value


TEXT = Codec(a_text, a_text, None, "x")
COUNT = Codec(a_count, parse_count, None, 1)
FLAG = Codec(a_flag, a_flag, None, sample=False)
# Annotated: with no expected type, pyright solves a choice's literals as str.
KIND: Codec[BlockerKind] = choice(BLOCKER_KINDS)
OUTCOME: Codec[Outcome] = choice(OUTCOMES)
VERDICT = Codec(
    a_verdict, parse_verdict, f"<requirement>={OUTCOME.shown}", Verdict("x", "met")
)
ROWS = Option("rows", "--row", "label", TEXT)
VERDICTS = Option("verdicts", "--verdict", "verdict", VERDICT)
TOUCHES: Option[Area] = Option("touches", "--touches", "area", choice(AREAS))
FAILING = Option("failing", "--failing", "check", TEXT)


def read_defaulted(f: Fields) -> Defaulted:
    knob: Knob = f.one("knob", choice(KNOBS))
    f.constant("value", DEFAULTS[knob])
    return Defaulted(knob)


# Keys are `name_of` each event; the readers take fields in the order read.
EVENTS: dict[str, Spec] = {
    "started": Spec(
        lambda f: Started(f.one("notes", TEXT), f.one("delegated", FLAG)),
        recordable=False,
    ),
    "quality": Spec(lambda f: Quality(f.one("mode", choice(MODES)))),
    "size": Spec(lambda f: Size(f.one("size", choice(SIZES)))),
    "grew": Spec(lambda f: Grew(f.one("why", TEXT))),
    "defaulted": Spec(read_defaulted, recordable=False),
    "researched": Spec(lambda f: Researched(f.optional("n", COUNT, 1))),
    "asked": Spec(lambda f: Asked(f.optional("n", COUNT, 1))),
    "planned": Spec(lambda f: Planned(f.one("path", TEXT))),
    "proposed": Spec(lambda f: Proposed(f.one("mode", choice(PROPOSAL_MODES)))),
    "confirmed": Spec(lambda _: Confirmed()),
    "adjusted": Spec(lambda _: Adjusted()),
    "drafted": Spec(lambda f: Drafted(f.one("pr", COUNT), f.one("base", TEXT))),
    "implemented": Spec(lambda f: Implemented(f.head())),
    "refactored": Spec(lambda f: Refactored(f.head())),
    "reviewed": Spec(
        lambda f: Reviewed(f.one("head", TEXT), f.many(ROWS), f.many(VERDICTS))
    ),
    "fixed": Spec(lambda f: Fixed(f.head(), f.many(TOUCHES))),
    "ci": Spec(lambda f: Ci(f.head(), f.many(FAILING))),
    # Keywords, evaluated left to right: the command line takes kind, role, question.
    "blocked": Spec(
        lambda f: Blocked(
            kind=f.one("kind", KIND),
            role=f.one("role", choice(ROLES, listed=False)),
            question=f.one("question", TEXT),
        )
    ),
    "resolved": Spec(
        lambda f: Resolved(f.one("question", TEXT), f.one("answer", TEXT))
    ),
    "overridden": Spec(
        lambda f: Overridden(f.one("to", choice(STATES)), f.one("why", TEXT)),
        recordable=False,
    ),
    "ready": Spec(lambda f: Ready(f.one("pr", COUNT))),
}

# ---- State --------------------------------------------------------------------


@dataclass(frozen=True)
class ReviewRound:
    head: str
    rows: tuple[str, ...]
    not_met: tuple[str, ...]


@dataclass(frozen=True)
class CiRound:
    head: str
    failing: tuple[str, ...]


@dataclass(frozen=True)
class OpenBlocker:
    question: str
    kind: BlockerKind
    role: Role


@dataclass(frozen=True)
class DoneBlocker:
    question: str
    kind: BlockerKind
    answer: str


type Round = ReviewRound | CiRound
type Blocker = OpenBlocker | DoneBlocker
# What the loop last did, which tells Impl'', DraftPR and PR what comes next.
type Work = Reviewed | Fixed | Ci


@dataclass(frozen=True)
class State:
    """`None` on a field is a fact not yet in the log: no run started, no knob
    chosen, no plan written, no PR opened, no commit seen, no loop work yet."""

    step: StateName = "Ctx"
    run: Started | None = None
    quality: Mode | None = None
    size: SizeName | None = None
    defaulted: tuple[Knob, ...] = ()
    researched: int = 0
    asked: int = 0
    plan: str | None = None
    proposed: frozenset[ProposalMode] = frozenset()
    pr: int | None = None
    base: str | None = None
    head: str | None = None
    # Reviews of the current plan: round 1 is the first, not counted.
    reviews: int = 0
    work: Work | None = None
    # Every round of the run, re-plans included: the stuck guard never resets.
    rounds: tuple[Round, ...] = ()
    blockers: tuple[Blocker, ...] = ()
    # Each question as it opened, in order: the stuck guard's third input.
    questions: tuple[str, ...] = ()


S0 = State()


@dataclass(frozen=True)
class Failure:
    """Something the caller can fix: a `what - why` line, a fix, an exit code."""

    message: str
    fix: str
    code: int


# ---- The table ----------------------------------------------------------------

# `classify` names an event's arrow; most kinds are the event's own name.
type Kind = Literal[
    "started", "started-delegated", "knob", "researched", "asked", "planned",
    "proposed", "confirmed", "confirmed-replan", "adjusted", "drafted", "implemented", "refactored",
    "reviewed-loop", "reviewed-final", "fixed", "ci", "blocked", "blocked-decision",
    "resolved", "ready",
]  # fmt: skip

LIVE: tuple[StateName, ...] = STATES[:-1]

# Every arrow but an override: (state, kind) -> target. A pair not here is an
# event the flow does not expect in that state; `state override` gets there.
TARGET: dict[tuple[StateName, Kind], StateName] = {
    ("Ctx", "started"): "Ctx",
    ("Ctx", "started-delegated"): "DraftPlan",
    **{(s, "knob"): s for s in LIVE},
    **{(s, "researched"): s for s in LIVE},
    **{(s, "blocked"): s for s in LIVE},
    **{(s, "blocked-decision"): "Ctx" for s in LIVE},
    **{(s, "resolved"): s for s in LIVE},
    ("Ctx", "asked"): "Ctx",
    ("Ctx", "planned"): "Prop",
    ("Prop", "proposed"): "Prop",
    ("Prop", "confirmed"): "DraftPlan",
    # A re-plan from a decision: the PR exists, so it resumes at step 5.
    ("Prop", "confirmed-replan"): "Impl",
    ("Prop", "adjusted"): "Ctx",
    ("DraftPlan", "drafted"): "Impl",
    ("Impl", "implemented"): "Impl'",
    ("Impl'", "implemented"): "Impl'",
    ("Impl'", "refactored"): "ImplR",
    # A review in Impl' is one whose refactor the guard skipped.
    ("Impl'", "reviewed-loop"): "Impl''",
    ("Impl'", "reviewed-final"): "DraftPR",
    ("ImplR", "reviewed-loop"): "Impl''",
    ("ImplR", "reviewed-final"): "DraftPR",
    ("Impl''", "reviewed-loop"): "Impl''",
    ("Impl''", "reviewed-final"): "DraftPR",
    ("Impl''", "fixed"): "Impl''",
    ("DraftPR", "fixed"): "DraftPR",
    ("DraftPR", "ci"): "PR",
    ("PR", "ci"): "PR",
    ("PR", "fixed"): "PR",
    ("PR", "reviewed-loop"): "PR",
    ("PR", "reviewed-final"): "PR",
    ("PR", "ready"): "Done",
}

# The `## States` block of the engineer skill, which pastes it from `state render`.
STEPS: tuple[tuple[str, str, str], ...] = (
    ("1-2", "Ctx", "research and ask on demand, any order, then a plan: 3"),
    ("3", "Prop", "simplify, alternative, then ask: first or second plan: 4; adjust: 2"),
    ("4", "DraftPlan", "draft PR with the plan: 5"),
    ("5", "Impl", "implement: 6"),
    ("6", "Impl'", "refactor: 7"),
    ("7", "ImplR", "first review: rows to fix: 8; none: final fixer, 9"),
    ("8", "Impl''", "fix, then a `--fixes` review: 8 while rounds remain; cap: final fixer, 9"),
    ("9", "DraftPR", "notify: 10"),
    ("10", "PR", "green CI: ready and notify; CI issues: `review.md`'s CI fix, then CI again"),
    ("any", "blocker", "a worker's `NEEDS_DECISION`: triage in `blockers.md`"),
    ("any", "stuck", "the stuck guard above: ask"),
)  # fmt: skip

STATES_INTRO = "Each step is a state. Quality and Size skip arrows, never add them."
STATES_FOOTER = """\
Every Quality and Size keeps the quick security review, the blocker arrows,
fact-gap research and the final fixer. A re-plan from a blocker follows
your Quality row too."""

# The engineer's rows of the Quality table in `quality.md`, as the guards read them.
QUALITY_ROWS: tuple[tuple[str, dict[Mode, str]], ...] = (
    ("Researchers", {
        "POC": "1 for all, 8 calls, notes past the hand-back limit",
        "Balanced": "up to 3, 15 calls, notes",
        "Max": "one per group, 30 calls, notes, top 5 facts re-checked",
    }),
    ("Proposals", {"POC": "simplify", "Balanced": "simplify, alternative", "Max": "simplify, alternative"}),
    ("Implement", {
        "POC": "one implementer, one happy-path proof as its test",
        "Balanced": "as planned",
        "Max": "as planned",
    }),
    ("Refactor", {
        "POC": "quick: items 1-3, no `tests.md`",
        "Balanced": "above about 100 changed lines",
        "Max": "always",
    }),
    ("Skill dry run", {"POC": "never", "Balanced": "new or rewritten skill", "Max": "any skill change"}),
    ("Re-reviews", {"POC": "1, blockers and Not met fixed only", "Balanced": "up to 2", "Max": "up to 3"}),
    ("Full review of a fix to", {
        "POC": "interface, data model, auth",
        "Balanced": "data model, auth",
        "Max": "interface, data model, auth",
    }),
)  # fmt: skip
QUALITY = dict(QUALITY_ROWS)

# The guards behind those rows.
PROPOSALS: dict[Mode, tuple[ProposalMode, ...]] = {
    "POC": ("simplify",),
    "Balanced": ("simplify", "alternative"),
    "Max": ("simplify", "alternative"),
}
REFACTOR_ABOVE = 100  # Balanced's "about 100 changed lines"
RE_REVIEWS: dict[Mode, int] = {"POC": 1, "Balanced": 2, "Max": 3}
FULL_REVIEW: dict[Mode, frozenset[Area]] = {
    "POC": frozenset(AREAS),
    "Balanced": frozenset({"data-model", "auth"}),
    "Max": frozenset(AREAS),
}

# ---- Brief text (verbatim from the engineer skill and its references) ----------

STOP_RULE = """\
> A question that blocks your work and that the repo, this brief and the plan
> do not settle, or choosing differently from a decision the plan states:
> stop at once. Commit and push the work you have, if any, as a
> normal commit with no WIP marker and `Remaining: <what is left>` in its
> body, plus `(does not build yet)` when it does not build.
> Start your hand-back with `NEEDS_DECISION <question>`, then that commit, what
> you tried and the evidence paths. Spawn no researcher.
> On `Size: Trivial`, work bigger than briefed is `GREW <why>`: stop the same
> way, after committing and pushing what you have, and start your hand-back
> with that line. With a `NEEDS_DECISION`, that line comes first and `GREW`
> on the next."""

PLAN_WRONG = """\
> The plan is wrong when a finding shows a wrong approach, a requirement that
> cannot be met, scope the plan does not hold, or a data-model or auth
> redesign. Do not stop early: finish the review, then make
> `NEEDS_DECISION plan wrong: <finding>` the first line of your return, before
> the usual report. Every other finding, security included, goes in the table
> as usual."""

HANDBACK_RULE = (
    "Hand back in about 250 words, never over 300: commit, proof, what remains; "
    "anything longer goes in a notes file outside the repo, and you hand back its "
    "path. Start your hand-back with READY, NEEDS_DECISION, GREW, BLOCKED or FAILED."
)


def resume_text(head: str) -> str:
    return (
        f"continue from commit `{head}`: its body says what remains; when it says "
        "it does not build, make it build first"
    )


def r0_text(base: str) -> str:
    return (
        "R0: the PR body describes the branch in the form `pr-description` picks, "
        f"read from `ctx diff origin/{base}`; keep any decisions made on the user's "
        "behalf, every recorded reason for an unfixed row, the research and "
        "decisions log, and `## Follow-ups`"
    )


class UsageFields:
    """Reads no value: records each field's usage word, returns a sample."""

    def __init__(self) -> None:
        self.words: list[str] = []

    def one[T](self, name: str, codec: Codec[T]) -> T:
        self.words.append(codec.shown or f"<{name}>")
        return codec.sample

    def optional[T](self, name: str, codec: Codec[T], default: T) -> T:
        _ = codec
        self.words.append(f"[<{name}>]")
        return default

    def head(self) -> str:
        self.words.append("[<head>]")
        return TEXT.sample

    def many[T](self, option: Option[T]) -> tuple[T, ...]:
        self.words.append(
            f"[{option.flag} {option.codec.shown or f'<{option.meta}>'}]..."
        )
        return ()

    def constant(self, name: str, value: Json) -> None:
        _ = name, value


def usage_of(name: str, spec: Spec) -> str:
    fields = UsageFields()
    _ = spec.read(fields)
    return " ".join((name, *fields.words))


COLUMNS = (30, 26, 26)  # the event grid of HELP; a wider usage gets a line


def grid(cells: Iterable[str]) -> str:
    rows: list[list[str]] = []
    for cell in cells:
        match rows:
            case [*_, last] if len(last) < len(COLUMNS) and all(
                len(c) < width for c, width in zip([*last, cell], COLUMNS, strict=False)
            ):
                last.append(cell)
            case _:
                rows.append([cell])
    return "".join(
        "  "
        + "".join(c.ljust(w) for c, w in zip(row, COLUMNS, strict=False)).rstrip()
        + "\n"
        for row in rows
    )


HELP = f"""\
state - record the engineer flow as events; advise the next arrow

  state init --notes <dir> [--delegated]   start a run: <dir>/events.jsonl
  state record <event> [args]              append one event (below)
  state handback <role> [options] < text   parse a worker's hand-back, record it
  state next                               the advised next arrow
  state brief <role>                       a brief skeleton for <role>
  state show                               the progress view
  state override <state> <why>             move to <state> off the advised arrow
  state render                             the skill's States block and Quality rows

Events
{grid(usage_of(name, spec) for name, spec in EVENTS.items() if spec.recordable)}\
  <head> omitted: HEAD. A row's label stays the same for the same finding.
  ci with no --failing: green.

Hand-backs   roles: {" ".join(WORKERS)}
  line 1 READY | NEEDS_DECISION <q> | GREW <why> | BLOCKED <r> | FAILED <r>
  --kind {KIND.shown}   the triage of a question; a
                                         `plan wrong:` or `stuck:` one is a decision
  --touches <area>...                    fixer: what its fix touched
  review-lead: its `Reviewed head: <sha>` line; --row and --verdict as reviewed
Brief roles  {" ".join(ROLES)}
States       {" ".join(STATES)}

Output (stdout)
  next     line 1 the advice alone: SPAWN <role> | ASK <what> | WAIT <what> |
           RUN <cmd> | STUCK <why> | DONE; then indented facts
  record   recorded <seq> <event> -> <state>, one line per event appended
The run's notes directory is the one `state init` last named in this worktree.
Exit     0 ok  2 bad usage, bad log line or unexpected event  1 git or disk failure
Errors go to stderr with a fix: line. The log is append-only; nothing rewrites it.
"""

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
        case Blocked(kind="decision"):
            return "blocked-decision"
        case Confirmed() if state.pr is not None:
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


def not_met(verdicts: tuple[Verdict, ...]) -> tuple[str, ...]:
    return tuple(v.requirement for v in verdicts if v.outcome == "not-met")


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
        case Drafted(pr=pr, base=base):
            return replace(state, pr=pr, base=base)
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
            if any(b.question == q for b in open_blockers(state)):
                return replace(state, blockers=settle(state, q, lambda _: opened))
            return replace(
                state,
                blockers=(*state.blockers, opened),
                questions=(*state.questions, q),
            )
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


def mode_of(state: State) -> Mode:
    """Quality as the guards read it: a missing knob is its default."""
    return state.quality or DEFAULT_QUALITY


def size_of(state: State) -> SizeName:
    return state.size or DEFAULT_SIZE


def name_of(event: Event) -> str:
    return type(event).__name__.lower()


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
    """The next arrow: stuck first, then an open blocker, then the step's own."""
    step = advise_step(state, facts)
    match stuck_why(state), first_open(state):
        case str() as why, _:
            return Stuck(
                why,
                (
                    handback_line(f"NEEDS_DECISION stuck: {why}")
                    if delegated(state)
                    else "ask the user: what changes so the next round differs",
                    f"advice once settled: {render_advice(step).splitlines()[0]}",
                ),
            )
        case None, OpenBlocker() as blocker:
            return advise_blocker(state, blocker)
        case None, None:
            return step


def first_open(state: State) -> OpenBlocker | None:
    """The oldest open blocker other than a decision: a decision is the plan's
    path through Ctx, so the step's own advice carries it."""
    return next((b for b in open_blockers(state) if b.kind != "decision"), None)


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
    asked = state.questions
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
        case "scope" if delegated(state):
            return Done((handback_line(f"NEEDS_DECISION {q}"),))
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
    if delegated(state) and decisions:
        return Done((handback_line(f"NEEDS_DECISION {decisions[0].question}"),))
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
    return Run(
        f"state record planned {notes_of(state)}/plan.md",
        (
            *(f"decision path for {quoted(b.question)}" for b in decisions),
            f"researchers {state.researched} ({researchers})",
            f"questions {state.asked} (at least 1, typically 4-12)",
            "research and ask on demand, any order; when nothing is open, write the plan",
            "each: state record researched | state record asked",
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
                        f"picked, a re-plan: gh pr edit {state.pr} --body-file <the chosen "
                        "plan with its Considered options>; it resumes at 5 on the same branch"
                    )
                ]
                if state.pr is not None
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
    record = "then: state record drafted <pr> <base>"
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
                        "notify, with: /qa <PR URL>  /final-review --requirements "
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
        "<the brief's task>-fixes.md"
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
    return state.base or "<base>"


def pr_ref(state: State) -> str:
    return str(state.pr) if state.pr is not None else "<pr>"


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
    mode, size = mode_of(state), size_of(state)
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
            first, tail = f"Quality: {mode}", [HANDBACK_RULE]
    head = [
        *(["<the first line of your spawn prompt>"] if delegated(state) else []),
        first,
        f"Size: {size}",
        f"Worktree: {worktree} (every command runs here)",
        f"Base: origin/{base}",
        f"Plan: {state.plan or '<plan path>'}",
    ]
    body = role_lines(role, state)
    return "".join(f"{line}\n" for line in (*head, *body, "", *tail))


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
            f"Re-review: {max(state.reviews - 1, 0)}/{cap(state)}   "
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


# ---- The log ------------------------------------------------------------------


@dataclass(frozen=True)
class Line:
    seq: int
    ts: str
    head: str | None
    session: str | None
    event: Event


def parse_log(text: str, path: Path) -> list[Line] | Failure:
    """Strict JSON Lines: every line one object, `\\n`-terminated, `seq` dense
    from 1. A bad line is an error naming it, never skipped."""
    if text and not text.endswith("\n"):
        return bad_line(path, text.count("\n") + 1, "no newline at its end")
    lines: list[Line] = []
    for n, raw in enumerate(text.splitlines(), start=1):
        try:
            line = decode_line(raw)
        except BadFieldError as error:
            return bad_line(path, n, str(error))
        if line.seq != n:
            return bad_line(path, n, f"seq is {line.seq}, expected {n}")
        lines.append(line)
    return lines


def replay(lines: list[Line], path: Path) -> State | Failure:
    match fold_or_stop((line.event for line in lines), S0):
        case State() as state:
            return state
        case n, failure:
            return bad_line(path, lines[n - 1].seq, failure.message)


def bad_line(path: Path, n: int, why: str) -> Failure:
    return Failure(
        f"state: {path}:{n}: {why}",
        (
            f"repair or delete line {n} of {path}: the log is append-only, so a bad "
            "line is a hand edit"
        ),
        2,
    )


def encode_line(line: Line) -> str:
    return (
        json.dumps(
            {
                "seq": line.seq,
                "ts": line.ts,
                "head": line.head,
                "session": line.session,
                "event": encode_event(line.event),
            },
            ensure_ascii=False,
            separators=(",", ":"),
        )
        + "\n"
    )


def encode_event(event: Event) -> dict[str, Json]:
    """The event's fields under their names, checked and completed by its read."""
    obj: dict[str, Json] = {"type": name_of(event)}
    obj.update(
        (f.name, to_json(cast("object", getattr(event, f.name)))) for f in fields(event)
    )
    reader = JsonFields(obj, writing=True)
    _ = EVENTS[name_of(event)].read(reader)
    reader.done(f"event {name_of(event)}")
    return obj


def to_json(value: object) -> Json:
    match value:
        case Verdict(requirement=requirement, outcome=outcome):
            return {"requirement": requirement, "outcome": outcome}
        case tuple():
            return [to_json(v) for v in cast("tuple[object, ...]", value)]
        case _:
            return cast("Json", value)


def decode_line(raw: str) -> Line:
    try:
        parsed = cast("Json", json.loads(raw))
    except json.JSONDecodeError as error:
        raise BadFieldError(f"not JSON - {error.msg}") from error
    obj = an_object(parsed, "the line")
    exact(obj, {"seq", "ts", "head", "session", "event"}, "the line")
    seq = obj["seq"]
    if not isinstance(seq, int) or isinstance(seq, bool):
        raise BadFieldError("seq is not an integer")
    return Line(
        seq,
        text_of(obj, "ts"),
        optional_text(obj, "head"),
        optional_text(obj, "session"),
        decode_event(an_object(obj["event"], "event")),
    )


def decode_event(obj: dict[str, Json]) -> Event:
    kind = text_of(obj, "type")
    match EVENTS.get(kind):
        case None:
            raise BadFieldError(f"unknown event type '{kind}'")
        case spec:
            reader = JsonFields(obj)
            event = spec.read(reader)
            reader.done(f"event {kind}")
            return event


class JsonFields:
    """An event's JSON object. Writing fills in its constants, else checks them."""

    def __init__(self, obj: dict[str, Json], *, writing: bool = False) -> None:
        self.obj: dict[str, Json] = obj
        self.writing: bool = writing
        self.keys: set[str] = {"type"}

    def one[T](self, name: str, codec: Codec[T]) -> T:
        self.keys.add(name)
        return codec.decode(name, self.obj.get(name))

    def optional[T](self, name: str, codec: Codec[T], default: T) -> T:
        _ = default
        return self.one(name, codec)

    def head(self) -> str:
        return self.one("head", TEXT)

    def many[T](self, option: Option[T]) -> tuple[T, ...]:
        self.keys.add(option.name)
        value = self.obj.get(option.name)
        if not isinstance(value, list):
            raise BadFieldError(f"{option.name} is not a list")
        return tuple(option.codec.decode(option.name, v) for v in value)

    def constant(self, name: str, value: Json) -> None:
        self.keys.add(name)
        if self.writing:
            self.obj[name] = value
        elif self.obj.get(name) != value:
            raise BadFieldError(f"{name} is not {value}")

    def done(self, what: str) -> None:
        exact(self.obj, self.keys, what)


def exact(obj: dict[str, Json], keys: set[str], what: str) -> None:
    if set(obj) != keys:
        missing, extra = sorted(keys - set(obj)), sorted(set(obj) - keys)
        raise BadFieldError(f"{what}: missing {missing}, unknown {extra}")


def text_of(obj: dict[str, Json], key: str) -> str:
    return a_text(key, obj.get(key))


def optional_text(obj: dict[str, Json], key: str) -> str | None:
    return None if obj.get(key) is None else text_of(obj, key)


# ---- The command line ----------------------------------------------------------


@dataclass(frozen=True)
class Help:
    """`state`, `state help` or `-h`/`--help` anywhere."""


@dataclass(frozen=True)
class Init:
    notes: Path
    delegated: bool


@dataclass(frozen=True)
class RecordCmd:
    """`record`'s arguments, parsed once HEAD is known."""

    args: tuple[str, ...]


@dataclass(frozen=True)
class HandbackCmd:
    role: Worker
    options: HandbackOptions


@dataclass(frozen=True)
class Next:
    pass


@dataclass(frozen=True)
class BriefCmd:
    role: Role


@dataclass(frozen=True)
class Show:
    pass


@dataclass(frozen=True)
class Override:
    to: StateName
    why: str


@dataclass(frozen=True)
class Render:
    pass


type Command = Init | RecordCmd | HandbackCmd | Next | BriefCmd | Show | Override


def parse_args(argv: list[str]) -> Help | Render | Command | Failure:  # noqa: C901, PLR0911, PLR0912 - one arm per command
    """Read the command line; never touches git or the log."""
    match argv:
        case [] | ["help"]:
            return Help()
        case _ if "-h" in argv or "--help" in argv:
            return Help()
        case ["init", "--notes", notes]:
            return Init(Path(notes), delegated=False)
        case ["init", "--notes", notes, "--delegated"] | [
            "init",
            "--delegated",
            "--notes",
            notes,
        ]:
            return Init(Path(notes), delegated=True)
        case ["init", *_]:
            return usage(
                "init takes --notes <dir> [--delegated]",
                "state init --notes /tmp/engineer-<owner>-<repo>-<slug>",
            )
        case ["record", *args] if args:
            return RecordCmd(tuple(args))
        case ["handback", role, *opts]:
            match pick(role, WORKERS), parse_options(opts):
                case None, _:
                    return usage(
                        f"handback: no role '{role}'", "roles: " + ", ".join(WORKERS)
                    )
                case _, Failure() as failure:
                    return failure
                case worker, HandbackOptions() as options:
                    return HandbackCmd(worker, options)
        case ["next"]:
            return Next()
        case ["brief", role]:
            match pick(role, ROLES):
                case None:
                    return usage(
                        f"brief: no role '{role}'", "roles: " + ", ".join(ROLES)
                    )
                case found:
                    return BriefCmd(found)
        case ["show"]:
            return Show()
        case ["override", to, why] if why.strip():
            match pick(to, STATES):
                case None:
                    return usage(
                        f"override: no state '{to}'", "states: " + " ".join(STATES)
                    )
                case found:
                    return Override(found, why)
        case ["render"]:
            return Render()
        case [command, *_] if command in (
            "record",
            "brief",
            "override",
            "next",
            "show",
            "render",
        ):
            return usage(f"{command}: wrong arguments", "state --help")
        case _:
            return usage(
                (
                    f"unknown command '{argv[0]}'. Commands: init, record, handback, next, "
                    "brief, show, override, render"
                ),
                "state --help",
            )


def parse_record(args: tuple[str, ...], head: str | None) -> Event | Failure:
    """`state record <event> [args]`; a `<head>` left out is HEAD."""
    name, *rest = args
    match EVENTS.get(name):
        case Spec(recordable=True) as spec:
            try:
                reader = ArgvFields(rest, head)
                event = spec.read(reader)
                reader.done()
            except BadFieldError as error:
                return usage(
                    f"record {name}: {error}", f"state record {usage_of(name, spec)}"
                )
            return event
        case _:
            return usage(f"record: no event '{name}'", "state --help lists the events")


def parse_options(opts: list[str]) -> HandbackOptions | Failure:
    try:
        reader = ArgvFields(opts, None)
        kinds = reader.many(Option("kind", "--kind", "kind", KIND))
        options = HandbackOptions(
            kinds[0] if kinds else None,
            reader.many(TOUCHES),
            reader.many(ROWS),
            reader.many(VERDICTS),
        )
        reader.done()
    except BadFieldError as error:
        return usage(f"handback: {error}", "state --help")
    return options


class ArgvFields:
    """Arguments: positionals in the order read, then `--flag <value>` pairs."""

    def __init__(self, args: Sequence[str], head: str | None) -> None:
        split = next((i for i, a in enumerate(args) if a.startswith("--")), len(args))
        flags = args[split:]
        if len(flags) % 2:
            raise BadFieldError(f"option '{flags[-1]}' needs a value")
        self.positionals: list[str] = list(args[:split])
        self.options: list[tuple[str, str]] = list(
            zip(flags[::2], flags[1::2], strict=True)
        )
        self.head_or_none: str | None = head

    def one[T](self, name: str, codec: Codec[T]) -> T:
        if not self.positionals:
            raise BadFieldError(f"no <{name}>")
        return codec.parse(name, self.positionals.pop(0))

    def optional[T](self, name: str, codec: Codec[T], default: T) -> T:
        return self.one(name, codec) if self.positionals else default

    def head(self) -> str:
        match self.positionals, self.head_or_none:
            case [], None:
                raise BadFieldError("no HEAD here, name the <head>")
            case [], str() as head:
                return head
            case _:
                return self.one("head", TEXT)

    def many[T](self, option: Option[T]) -> tuple[T, ...]:
        found = [value for flag, value in self.options if flag == option.flag]
        self.options = [(f, v) for f, v in self.options if f != option.flag]
        return tuple(option.codec.parse(option.name, v) for v in found)

    def constant(self, name: str, value: Json) -> None:
        """Never on the command line: a constant is derived, not given."""
        _ = name, value

    def done(self) -> None:
        match self.positionals, self.options:
            case [], []:
                pass
            case [extra, *_], _:
                raise BadFieldError(f"unexpected '{extra}'")
            case _, [(flag, _), *_]:
                raise BadFieldError(f"unknown option '{flag}'")
            case _:
                pass


def usage(message: str, fix: str) -> Failure:
    return Failure(f"state {message}", fix, 2)


# ---- The shell ------------------------------------------------------------------

LOG = "events.jsonl"
# Per worktree, so each run in its own worktree finds its own log.
POINTER = "state-notes"
LOCKFILES = ("flake.lock", "package-lock.json", "pnpm-lock.yaml")


class GitError(Exception):
    """A git command that should not fail did: an outage, not a bad ref."""


def main(argv: list[str], cwd: Path, stdin: str | None = None) -> int:  # noqa: PLR0911 - one arm per outcome
    parsed = parse_args(argv)
    match parsed:
        case Help():
            _ = sys.stdout.write(HELP)
            return 0
        case Render():
            _ = sys.stdout.write(render())
            return 0
        case Failure():
            return report(parsed)
        case _:
            try:
                result = execute(parsed, cwd, stdin)
            except GitError as error:
                return report(
                    Failure(
                        f"state: git failed - {error}",
                        "run that git command here to see why",
                        1,
                    )
                )
            except OSError as error:
                return report(
                    Failure(
                        f"state: cannot read or write the log - {error}",
                        "check the notes directory's path and access",
                        1,
                    )
                )
            match result:
                case str():
                    _ = sys.stdout.write(result)
                    return 0
                case Failure():
                    return report(result)


def execute(command: Command, cwd: Path, stdin: str | None) -> str | Failure:  # noqa: C901, PLR0911, PLR0912 - one arm per command
    match locate(cwd):
        case Failure() as failure:
            return failure
        case git_dir:
            pass
    if isinstance(command, Init):
        return init(git_dir, command, head_of(cwd))
    match load(git_dir):
        case Failure() as failure:
            return failure
        case (log, lines, state):
            pass
    match command:
        case RecordCmd(args=args):
            match parse_record(args, head_of(cwd)):
                case Failure() as failure:
                    return failure
                case event:
                    return append(log, lines, state, (event,), cwd)
        case HandbackCmd(role=role, options=options):
            text = sys.stdin.read() if stdin is None else stdin
            match parse_handback(role, text, options, head_of(cwd)):
                case Failure() as failure:
                    return failure
                case events:
                    return append(log, lines, state, events, cwd)
        case Override(to=to, why=why):
            return append(log, lines, state, (Overridden(to, why),), cwd)
        case Next():
            facts = NoFacts() if state.base is None else git_facts(cwd, state.base)
            return render_advice(advise(state, facts))
        case BriefCmd(role=role):
            return brief(role, state, toplevel(cwd))
        case Show():
            return show(state)


def init(git_dir: Path, command: Init, head: str | None) -> str | Failure:
    """Idempotent: a log that holds its `started` line gets nothing more."""
    notes = command.notes.absolute()
    log = notes / LOG
    notes.mkdir(parents=True, exist_ok=True)
    _ = (git_dir / POINTER).write_text(f"{notes}\n")
    if log.exists() and log.read_text():
        match read_log(log):
            case Failure() as failure:
                return failure
            case _:
                return f"{log}\nstarted: already\n"
    line = Line(1, now(), head, session(), Started(str(notes), command.delegated))
    with log.open("a") as file:
        _ = file.write(encode_line(line))
    return f"{log}\nstarted: yes\n"


def load(git_dir: Path) -> tuple[Path, list[Line], State] | Failure:
    pointer = git_dir / POINTER
    if not pointer.exists():
        return Failure(
            "state: no run in this worktree",
            "state init --notes /tmp/engineer-<owner>-<repo>-<slug>",
            2,
        )
    log = Path(pointer.read_text().strip()) / LOG
    match read_log(log):
        case Failure() as failure:
            return failure
        case lines, state:
            return log, lines, state


def read_log(log: Path) -> tuple[list[Line], State] | Failure:
    """The log's lines and the state they replay to; no log is an empty one."""
    match parse_log(log.read_text() if log.exists() else "", log):
        case Failure() as failure:
            return failure
        case lines:
            pass
    match replay(lines, log):
        case Failure() as failure:
            return failure
        case state:
            return lines, state


def append(
    log: Path, lines: list[Line], state: State, events: tuple[Event, ...], cwd: Path
) -> str | Failure:
    match record(state, events):
        case Failure() as failure:
            return replace(failure, message=f"state record: {failure.message}")
        case appended, reached:
            pass
    head, ts, sess = head_of(cwd), now(), session()
    new = [
        Line(len(lines) + i, ts, head, sess, e) for i, e in enumerate(appended, start=1)
    ]
    try:
        text = "".join(encode_line(line) for line in new)
    except BadFieldError as error:  # a hand-back line with nothing after its token
        return usage(f"record: {error}", "give the hand-back's line 1 its text")
    # One write per call, so lines of one call never interleave with another's.
    with log.open("a") as file:
        _ = file.write(text)
    return "".join(
        f"recorded {line.seq} {name_of(line.event)} -> {reached.step}\n" for line in new
    )


def git_facts(cwd: Path, base: str) -> GitFacts:
    out = git(cwd, "diff", "--numstat", "--summary", f"origin/{base}...HEAD")
    return parse_numstat(out)


def parse_numstat(out: str) -> GitFacts:
    """`git diff --numstat --summary`: lockfiles and binary rows add no lines."""
    lines, skills = 0, "none"
    for row in out.splitlines():
        parts = row.split("\t")
        match parts:
            case [added, deleted, path] if added.isdigit() and deleted.isdigit():
                if not is_lockfile(path):
                    lines += int(added) + int(deleted)
                if path.endswith("SKILL.md") and skills == "none":
                    skills = "changed"
            case [summary] if summary.strip().startswith(
                "create mode"
            ) and summary.endswith("SKILL.md"):
                skills = "new"
            case _:
                pass
    return GitFacts(lines, skills)


def is_lockfile(path: str) -> bool:
    name = path.rsplit("/", 1)[-1]
    return name in LOCKFILES or name.endswith(".lock")


def locate(cwd: Path) -> Path | Failure:
    found = run_git(cwd, "rev-parse", "--absolute-git-dir")
    if found.returncode != 0:
        return Failure(
            f"state: not inside a git work tree (cwd {cwd})",
            "cd <worktree>; state keeps one run per worktree",
            2,
        )
    return Path(found.stdout.strip())


def head_of(cwd: Path) -> str | None:
    found = run_git(cwd, "rev-parse", "--verify", "--quiet", "HEAD")
    return found.stdout.strip() or None if found.returncode == 0 else None


def toplevel(cwd: Path) -> str:
    return git(cwd, "rev-parse", "--show-toplevel").strip()


def now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def session() -> str | None:
    """The runner's session id, when it exports one as STATE_SESSION."""
    return os.environ.get("STATE_SESSION") or None


def report(failure: Failure) -> int:
    _ = sys.stderr.write(f"{failure.message}\nfix: {failure.fix}\n")
    return failure.code


def git(cwd: Path, *args: str) -> str:
    done = run_git(cwd, *args)
    if done.returncode != 0:
        raise GitError(f"git {' '.join(args)}: {done.stderr.strip()}")
    return done.stdout


def run_git(cwd: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args], cwd=cwd, check=False, capture_output=True, text=True
    )


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], Path.cwd()))
