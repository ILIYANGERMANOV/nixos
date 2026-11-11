"""The domain: the vocabulary, the events, the state they fold into and the
failure a caller can fix. Types only, plus the few queries every module reads."""

from dataclasses import dataclass
from typing import Literal, TypeAliasType, cast, get_args

# ---- Vocabulary ---------------------------------------------------------------

type StateName = Literal[
    "Ctx",
    "Propose",
    "DraftPlan",
    "Implement",
    "Refactor",
    "Review",
    "Fix",
    "DraftPR",
    "PR",
    "Done",
]
type Mode = Literal["POC", "Balanced", "Max"]
type SizeName = Literal["Trivial", "Normal"]
type Knob = Literal["quality", "size"]
type ProposalMode = Literal["simplify", "alternative"]
type BlockerKind = Literal["answered", "fact", "decision", "scope"]
# In the Quality table's order: `flow.areas_text` prints them so.
type Area = Literal["interface", "data-model", "auth"]
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
# A worker hand-back's first word: its status.
type Token = Literal["READY", "NEEDS_DECISION", "GREW", "BLOCKED", "FAILED"]


def values_of(alias: TypeAliasType) -> tuple[str, ...]:
    """A `type X = Literal[...]` alias's values, in order: one list per name."""
    value: object = alias.__value__  # pyright: ignore[reportAny] - typeshed says Any
    return cast("tuple[str, ...]", get_args(value))


STATES = cast("tuple[StateName, ...]", values_of(StateName))
MODES = cast("tuple[Mode, ...]", values_of(Mode))
SIZES = cast("tuple[SizeName, ...]", values_of(SizeName))
PROPOSAL_MODES = cast("tuple[ProposalMode, ...]", values_of(ProposalMode))
BLOCKER_KINDS = cast("tuple[BlockerKind, ...]", values_of(BlockerKind))
AREAS = cast("tuple[Area, ...]", values_of(Area))
OUTCOMES = cast("tuple[Outcome, ...]", values_of(Outcome))
ROLES = cast("tuple[Role, ...]", values_of(Role))
WORKERS = cast("tuple[Worker, ...]", values_of(Worker))
KNOBS = cast("tuple[Knob, ...]", values_of(Knob))
TOKENS = cast("tuple[Token, ...]", values_of(Token))
DEFAULT_QUALITY: Mode = "Balanced"
DEFAULT_SIZE: SizeName = "Normal"
DEFAULTS: dict[Knob, str] = {"quality": DEFAULT_QUALITY, "size": DEFAULT_SIZE}

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
    """The draft PR, by its URL: the branch it targets and its head branch, the
    one the run is bound to."""

    url: str
    base: str
    branch: str


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
    """A review's return, by its `Reviewed head`. The lead's picks follow."""

    head: str


@dataclass(frozen=True)
class Picked:
    """The lead's picks from the review before it: the rows to fix, labelled so
    the same finding keeps its label across rounds, and the verdicts."""

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
class Simplified:
    """The PR body rewritten to `pr-description`'s short shape (row S0), on
    `head`. Nothing clears it: an R0 after it edits in place, keeping the shape."""

    head: str


@dataclass(frozen=True)
class Raised:
    """A worker's question as its hand-back put it, waiting for the lead's
    triage: a `blocked` of the same question."""

    question: str
    role: Role


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
    url: str


@dataclass(frozen=True)
class Refused:
    """A `state record` or `state handback` the run refused: stored, so the next
    view still warns about it after the agent moved on."""

    message: str
    fix: str


type Event = (
    Started | Quality | Size | Grew | Defaulted | Researched | Asked | Planned | Proposed
    | Confirmed | Adjusted | Drafted | Implemented | Refactored | Reviewed | Picked | Fixed
    | Ci | Simplified | Raised | Blocked | Resolved | Overridden | Ready | Refused
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
class UntriagedBlocker:
    question: str
    role: Role


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
type Blocker = UntriagedBlocker | OpenBlocker | DoneBlocker
# What the loop last did, which tells Fix, DraftPR and PR what comes next. A
# Reviewed is a review back whose picks the lead has not recorded yet.
type Work = Reviewed | Picked | Fixed | Ci


@dataclass(frozen=True)
class State:
    """`None` on a field is a fact not yet in the log: no run started, no knob
    chosen, no plan written, no draft PR opened, no commit seen, no loop work yet."""

    step: StateName = "Ctx"
    run: Started | None = None
    quality: Mode | None = None
    size: SizeName | None = None
    defaulted: tuple[Knob, ...] = ()
    researched: int = 0
    asked: int = 0
    plan: str | None = None
    proposed: frozenset[ProposalMode] = frozenset()
    drafted: Drafted | None = None
    head: str | None = None
    # Reviews of the current plan: round 1 is the first, not counted.
    reviews: int = 0
    work: Work | None = None
    # Every round of the run, re-plans included: the stuck guard never resets.
    rounds: tuple[Round, ...] = ()
    # In the order each question opened; a re-triage replaces it in place.
    blockers: tuple[Blocker, ...] = ()
    # The head S0 shortened the PR body on: `gh pr ready` waits for it.
    simplified: str | None = None
    # The last refusal, until the next accepted event or override.
    refused: Refused | None = None


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


# Events another command writes (`init`, a draft PR's defaults, `override`, a
# hand-back's untriaged question, a refusal), by `name_of`: `state record` refuses them, and
# no refusal names them as its fix. A question is recorded triaged: `blocked`.
UNRECORDABLE = frozenset({"started", "defaulted", "overridden", "raised", "refused"})
