"""The domain: the vocabulary, the events, the state they fold into and the
failure a caller can fix. Types only, plus the few queries every module reads."""

from dataclasses import dataclass
from typing import Literal

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


def not_met(verdicts: tuple[Verdict, ...]) -> tuple[str, ...]:
    return tuple(v.requirement for v in verdicts if v.outcome == "not-met")


def mode_of(state: State) -> Mode:
    """Quality as the guards read it: a missing knob is its default."""
    return state.quality or DEFAULT_QUALITY


def size_of(state: State) -> SizeName:
    return state.size or DEFAULT_SIZE


def name_of(event: Event) -> str:
    return type(event).__name__.lower()
