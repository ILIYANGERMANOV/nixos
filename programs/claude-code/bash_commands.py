"""Reads a Bash command as Bash would, for the PreToolUse guards.

`parse` is the interface. It runs shfmt, whose JSON stays inside this module, and
never raises: whatever goes wrong is an `Unparsable`, which a guard fails open on.
"""

import re
import subprocess
from collections.abc import Iterator
from dataclasses import dataclass, replace
from enum import Enum, IntEnum, auto
from typing import cast

from hook_event import Json, parse_json

# Substituted at build time: bash-guard.nix for a guard, `python-tests` for a test.
SHFMT = "@shfmt@"
SHFMT_TIMEOUT_SECONDS = 2
# Longest first, so that `>>` is never read as `>`.
OPERATORS = (
    "&>>",
    "<<<",
    "&>",
    ">>",
    ">&",
    ">|",
    "<<",
    "<&",
    "<>",
    ">",
    "<",
    "&&",
    "||",
    "|&",
    "|",
)
UNQUOTED_ESCAPE = re.compile(r"\\(.)", re.DOTALL)
DOUBLE_QUOTED_ESCAPE = re.compile(r'\\([$`"\\])')

PIPES = {"|", "|&"}


class Sink(Enum):
    """Where a simple command's stdout goes."""

    SCREEN = auto()
    FILE = auto()
    PIPE = auto()


class Loop(IntEnum):
    """What repeats a command. Nested, the larger wins: `max` of the two."""

    NONE = auto()
    OVER_LIST = auto()  # `for` and `select`
    ON_CONDITION = auto()  # `while` and `until`


@dataclass(frozen=True)
class Simple:
    """One simple command, with what it inherits from the compounds around it.

    Words have their quotes removed and keep expansions as source text. The
    arguments of `declare`, `export` and the like stay source text whole.
    """

    words: tuple[str, ...]
    sink: Sink = Sink.SCREEN
    background: bool = False
    looped: Loop = Loop.NONE
    substituted: bool = False  # inside `$(...)`, backticks or `<(...)`


@dataclass(frozen=True)
class Parsed:
    commands: tuple[Simple, ...]


@dataclass(frozen=True)
class Unparsable:
    reason: str


Script = Parsed | Unparsable

type Node = dict[str, Json]


def parse(command: str) -> Script:
    """Every simple command in `command`, those in substitutions included."""
    try:
        return read_script(command)
    except Exception as failure:  # noqa: BLE001 - a guard gets a Script, whatever shfmt does
        return Unparsable(repr(failure))


def read_script(command: str) -> Script:
    source = command.encode()
    shfmt = subprocess.run(
        [SHFMT, "--to-json", "-ln", "bash"],
        input=source,
        capture_output=True,
        timeout=SHFMT_TIMEOUT_SECONDS,
        check=False,
    )
    if shfmt.returncode != 0:
        return Unparsable(shfmt.stderr.decode(errors="replace").strip())
    tree = cast("Node", parse_json(shfmt.stdout))
    return Parsed(tuple(statements(children(tree, "Stmts"), Simple(()), source)))


def statements(nodes: list[Node], around: Simple, source: bytes) -> Iterator[Simple]:
    """`around` is an empty command holding what these inherit from their parents."""
    for node in nodes:
        yield from statement(node, around, source)


def statement(node: Node, around: Simple, source: bytes) -> Iterator[Simple]:
    if node.get("Background"):
        around = replace(around, background=True)
    sink = around.sink
    for redirect in children(node, "Redirs"):
        sink = sink_after(sink, redirect, source)
    if "Cmd" in node:
        yield from compound(child(node, "Cmd"), replace(around, sink=sink), source)
    yield from substitutions(node.get("Redirs"), around, source)


def sink_after(sink: Sink, redirect: Node, source: bytes) -> Sink:
    """Where stdout goes after one redirection."""
    operator = operator_at(redirect, source)
    default_fd = "0" if operator.startswith("<") else "1"
    fd = string(child(redirect, "N"), "Value") if "N" in redirect else default_fd
    match (fd, operator):
        case ("1", ">&") if word_text(child(redirect, "Word"), source).isdigit():
            return sink
        case ("1", ">" | ">>" | ">|" | ">&" | "<>") | (_, "&>" | "&>>"):
            return Sink.FILE
        case _:
            return sink


def compound(  # noqa: C901 - one arm per shfmt node type
    node: Node, around: Simple, source: bytes
) -> Iterator[Simple]:
    """The commands of one shfmt command node, simple ones included."""
    match node["Type"]:
        case "CallExpr":
            yield from call(node, around, source)
        case "DeclClause":
            words = [raw_text(argument, source) for argument in children(node, "Args")]
            variant = string(child(node, "Variant"), "Value")
            yield replace(around, words=(variant, *words))
            yield from substitutions(node, around, source)
        case "BinaryCmd":
            yield from binary(node, around, source)
        case "WhileClause":
            looped = replace(around, looped=Loop.ON_CONDITION)
            body = children(node, "Cond") + children(node, "Do")
            yield from statements(body, looped, source)
        case "ForClause":
            yield from for_clause(node, around, source)
        case "IfClause":
            yield from if_clause(node, around, source)
        case "Subshell" | "Block":
            yield from statements(children(node, "Stmts"), around, source)
        case "CaseClause":
            yield from substitutions(node["Word"], around, source)
            for item in children(node, "Items"):
                yield from substitutions(item.get("Patterns"), around, source)
                yield from statements(children(item, "Stmts"), around, source)
        case "FuncDecl":
            yield from statement(child(node, "Body"), around, source)
        case "TimeClause" | "CoprocClause" if "Stmt" in node:
            yield from statement(child(node, "Stmt"), around, source)
        case _:
            yield from substitutions(node, around, source)


def call(node: Node, around: Simple, source: bytes) -> Iterator[Simple]:
    arguments = children(node, "Args")
    if arguments:
        words = tuple(word_text(word, source) for word in arguments)
        yield replace(around, words=words)
    yield from substitutions(node, around, source)


def binary(node: Node, around: Simple, source: bytes) -> Iterator[Simple]:
    piped = operator_at(node, source) in PIPES
    left = replace(around, sink=Sink.PIPE) if piped else around
    yield from statement(child(node, "X"), left, source)
    yield from statement(child(node, "Y"), around, source)


def for_clause(node: Node, around: Simple, source: bytes) -> Iterator[Simple]:
    yield from substitutions(node["Loop"], around, source)
    looped = replace(around, looped=max(around.looped, Loop.OVER_LIST))
    yield from statements(children(node, "Do"), looped, source)


def if_clause(node: Node, around: Simple, source: bytes) -> Iterator[Simple]:
    """An `elif` or `else` is an `Else` node of the same shape, without a `Type`."""
    body = children(node, "Cond") + children(node, "Then")
    yield from statements(body, around, source)
    if "Else" in node:
        yield from if_clause(child(node, "Else"), around, source)


def substitutions(node: Json, around: Simple, source: bytes) -> Iterator[Simple]:
    """The commands of each `$(...)`, backtick and `<(...)` anywhere under a node."""
    match node:
        case {"Type": "CmdSubst" | "ProcSubst"}:
            inner = replace(around, sink=Sink.PIPE, substituted=True)
            yield from statements(children(node, "Stmts"), inner, source)
        case dict():
            for value in node.values():
                yield from substitutions(value, around, source)
        case list():
            for item in node:
                yield from substitutions(item, around, source)
        case _:
            pass


def word_text(word: Node, source: bytes) -> str:
    return "".join(part_text(part, source) for part in children(word, "Parts"))


def part_text(part: Node, source: bytes) -> str:
    match part["Type"]:
        case "Lit":
            return UNQUOTED_ESCAPE.sub(r"\1", string(part, "Value"))
        case "SglQuoted":  # shfmt omits an empty string
            return cast("str", part.get("Value", ""))
        case "DblQuoted":
            return "".join(
                double_quoted_text(p, source) for p in children(part, "Parts")
            )
        case _:
            return raw_text(part, source)


def double_quoted_text(part: Node, source: bytes) -> str:
    match part["Type"]:
        case "Lit":
            return DOUBLE_QUOTED_ESCAPE.sub(r"\1", string(part, "Value"))
        case _:
            return raw_text(part, source)


def raw_text(node: Node, source: bytes) -> str:
    return source[offset(node, "Pos") : offset(node, "End")].decode()


def operator_at(node: Node, source: bytes) -> str:
    """Read from the source: shfmt 3.14 changed how its JSON encodes operators."""
    start = offset(node, "OpPos")
    text = source[start : start + 3].decode(errors="replace")
    return next(op for op in OPERATORS if text.startswith(op))


# These trust shfmt's shape. One it does not have raises, and `parse` reports that.
def child(node: Node, key: str) -> Node:
    return cast("Node", node[key])


def children(node: Node, key: str) -> list[Node]:
    """shfmt omits an empty list."""
    return cast("list[Node]", node.get(key, []))


def string(node: Node, key: str) -> str:
    return cast("str", node[key])


def offset(node: Node, key: str) -> int:
    return cast("int", child(node, key)["Offset"])
