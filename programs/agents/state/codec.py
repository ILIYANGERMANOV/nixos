"""Pure: the event table, each event's fields described once, and the JSON
Lines log it reads and writes strictly."""

import json
import re
from collections.abc import Callable, Sequence
from dataclasses import dataclass, fields
from pathlib import Path
from typing import Protocol, cast

from state.core import fold_or_stop
from state.model import (
    AREAS,
    BLOCKER_KINDS,
    DEFAULTS,
    KNOBS,
    MODES,
    OUTCOMES,
    PROPOSAL_MODES,
    ROLES,
    S0,
    SIZES,
    STATES,
    Adjusted,
    Area,
    Asked,
    Blocked,
    BlockerKind,
    Ci,
    Confirmed,
    Defaulted,
    Drafted,
    Event,
    Failure,
    Fixed,
    Grew,
    Implemented,
    Json,
    Knob,
    Outcome,
    Overridden,
    Picked,
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
    Simplified,
    Size,
    Started,
    State,
    Verdict,
    name_of,
)

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


def a_pr_url(key: str, value: Json) -> str:
    """The URL `gh pr create` prints: https://<host>/<owner>/<repo>/pull/<n>."""
    url = a_text(key, value)
    if PR_URL_SHAPE.fullmatch(url) is None:
        raise BadFieldError(
            f"{key} '{url}' is not a PR URL, https://<host>/<owner>/<repo>/pull/<n>"
        )
    return url


PR_URL_SHAPE = re.compile(r"https://[^/\s]+/[^/\s]+/[^/\s]+/pull/[1-9][0-9]*")


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
PR_URL = Codec(a_pr_url, a_pr_url, "<pr-url>", "https://github.com/o/r/pull/1")
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
    "started": Spec(lambda f: Started(f.one("notes", TEXT), f.one("delegated", FLAG))),
    "quality": Spec(lambda f: Quality(f.one("mode", choice(MODES)))),
    "size": Spec(lambda f: Size(f.one("size", choice(SIZES)))),
    "grew": Spec(lambda f: Grew(f.one("why", TEXT))),
    "defaulted": Spec(read_defaulted),
    "researched": Spec(lambda f: Researched(f.optional("n", COUNT, 1))),
    "asked": Spec(lambda f: Asked(f.optional("n", COUNT, 1))),
    "planned": Spec(lambda f: Planned(f.one("path", TEXT))),
    "proposed": Spec(lambda f: Proposed(f.one("mode", choice(PROPOSAL_MODES)))),
    "confirmed": Spec(lambda _: Confirmed()),
    "adjusted": Spec(lambda _: Adjusted()),
    "drafted": Spec(
        lambda f: Drafted(
            f.one("url", PR_URL), f.one("base", TEXT), f.one("branch", TEXT)
        )
    ),
    "implemented": Spec(lambda f: Implemented(f.head())),
    "refactored": Spec(lambda f: Refactored(f.head())),
    "reviewed": Spec(lambda f: Reviewed(f.one("head", TEXT))),
    "picked": Spec(lambda f: Picked(f.many(ROWS), f.many(VERDICTS))),
    "fixed": Spec(lambda f: Fixed(f.head(), f.many(TOUCHES))),
    "ci": Spec(lambda f: Ci(f.head(), f.many(FAILING))),
    "simplified": Spec(lambda f: Simplified(f.head())),
    "raised": Spec(
        lambda f: Raised(
            role=f.one("role", choice(ROLES, listed=False)),
            question=f.one("question", TEXT),
        )
    ),
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
        lambda f: Overridden(f.one("to", choice(STATES)), f.one("why", TEXT))
    ),
    "ready": Spec(lambda f: Ready(f.one("url", PR_URL))),
    "refused": Spec(lambda f: Refused(f.one("message", TEXT), f.one("fix", TEXT))),
}


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
            "line is a hand edit, or a log an older state wrote; the state hooks "
            "stay silent until it parses"
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
