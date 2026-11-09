"""Pure: argv parsed into a command, and the usage (HELP), both read off the
event table."""

from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from difflib import get_close_matches
from pathlib import Path

from state.codec import (
    EVENTS,
    KIND,
    TEXT,
    BadFieldError,
    Codec,
    Option,
    Spec,
    pick,
)
from state.core import HandbackOptions
from state.model import (
    ROLES,
    STATES,
    TOKENS,
    UNRECORDABLE,
    WORKERS,
    Event,
    Failure,
    Json,
    Role,
    StateName,
    Token,
    Worker,
)

# ---- Usage --------------------------------------------------------------------


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


def token_usage(token: Token) -> str:
    match token:
        case "READY":
            return token
        case "NEEDS_DECISION":
            return f"{token} <q>"
        case "GREW":
            return f"{token} <why>"
        case "BLOCKED" | "FAILED":
            return f"{token} <r>"


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
  state handback <role> [--kind <k>]       record a worker's hand-back, on stdin
  state next                               the advised next arrow
  state brief <role>                       a brief skeleton for <role>
  state show                               the progress view
  state override <state> <why>             move to <state> off the advised arrow
  state render                             the skill's States block and Quality rows

Events
{grid(usage_of(name, spec) for name, spec in EVENTS.items() if name not in UNRECORDABLE)}\
  <head> omitted: HEAD. A row's label stays the same for the same finding.
  reviewed: a review back; picked: the lead's rows and verdicts from it.
  ci with no --failing: green.

Hand-backs   roles: {" ".join(WORKERS)}
  where the state hooks are installed, each is recorded as its worker hands back
  line 1 {" | ".join(token_usage(token) for token in TOKENS)}
  review-lead: its `Reviewed head: <sha>` line; the lead then records picked
  fixer: its `Touches: <area>...` line; none when left out
  a question waits for its triage, record blocked, unless --kind gives it
  ({KIND.shown}) or it starts `plan wrong:` or `stuck:`: a decision
Brief roles  {" ".join(ROLES)}
States       {" ".join(STATES)}

Output (stdout)
  next     line 1 the advice alone: SPAWN <role> | ASK <what> | WAIT <what> |
           RUN <cmd> | STUCK <why> | DONE; then indented facts
  record   recorded <seq> <event> -> <state>, one line per event appended
The run's notes directory is the one `state init` last named in this worktree.
Exit     0 ok  2 bad usage, bad log line or unexpected event  1 git or disk failure
An event that is not an arrow here is refused; its fix: line names the arrows
here and the override that makes it one. A refused record or hand-back is logged
as `refused`, and next and show start with a WARN line until the next event.
Errors go to stderr with a fix: line. The log is append-only; nothing rewrites it.
"""


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
    match None if name in UNRECORDABLE else EVENTS.get(name):
        case Spec() as spec:
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
            return usage(f"record: no event '{name}'", did_you_mean(name))


def did_you_mean(name: str) -> str:
    recordable = [n for n in EVENTS if n not in UNRECORDABLE]
    match get_close_matches(name, recordable, n=1):
        case [found]:
            return f"did you mean: state record {usage_of(found, EVENTS[found])}"
        case _:
            return "state --help lists the events"


def parse_options(opts: list[str]) -> HandbackOptions | Failure:
    try:
        reader = ArgvFields(opts, None)
        kinds = reader.many(Option("kind", "--kind", "kind", KIND))
        options = HandbackOptions(kinds[0] if kinds else None)
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
