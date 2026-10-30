"""Splits a Bash command into its simple commands, for the PreToolUse guards."""

import re
import shlex
from collections.abc import Iterator
from dataclasses import dataclass
from enum import Enum, auto

OPERATORS = set(";&|()<>")
PIPES = {"|", "|&"}
# `<<` or `<<-`, then the delimiter, bare or quoted. `<<<` is a here-string.
HEREDOC = re.compile(r"(?<!<)<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
# Bash starts a comment only at a word's start; shlex anywhere, so `.#ci` would
# swallow the rest of the command. A `bash -c` script is split again with the
# escape still on it, and a second one would escape the backslash, not the hash.
MID_WORD_HASH = re.compile(r"(?<=[^\s;&|()<>\\])#")


class Sink(Enum):
    """Where a simple command's stdout goes."""

    SCREEN = auto()
    FILE = auto()
    PIPE = auto()


@dataclass(frozen=True)
class SimpleCommand:
    words: list[str]
    sink: Sink


def simple_commands(command: str) -> Iterator[SimpleCommand]:
    """Each simple command, split at shell operators, with its stdout sink.

    Redirection operators and their targets are not words. A digit word
    before `>` is the fd it redirects, so `2>/dev/null` leaves stdout alone.
    """
    lexer = shlex.shlex(
        MID_WORD_HASH.sub(r"\\#", strip_heredoc_bodies(command)).replace("\n", " ; "),
        posix=True,
        punctuation_chars=True,
    )
    lexer.whitespace_split = True
    tokens = iter(lexer)
    words: list[str] = []
    sink = Sink.SCREEN
    for token in tokens:
        match token:
            case _ if not set(token) <= OPERATORS:
                words.append(token)
            case _ if token in PIPES:
                yield SimpleCommand(words, Sink.PIPE)
                words, sink = [], Sink.SCREEN
            case _ if ">" in token:
                fd = words.pop() if words and words[-1].isdigit() else "1"
                target = next(tokens, "")
                if redirects_stdout_to_file(fd, token, target):
                    sink = Sink.FILE
            case _ if "<" in token:
                next(tokens, "")
            case _:
                yield SimpleCommand(words, sink)
                words, sink = [], Sink.SCREEN
    yield SimpleCommand(words, sink)


def strip_heredoc_bodies(command: str) -> str:
    """The command without the body lines of its heredocs."""
    lines = iter(command.split("\n"))
    kept = []
    for line in lines:
        kept.append(line)
        for heredoc in HEREDOC.finditer(line):
            delimiter = heredoc.group(2)
            for body in lines:
                if body.strip() == delimiter:
                    break
    return "\n".join(kept)


def redirects_stdout_to_file(fd: str, operator: str, target: str) -> bool:
    match (fd, operator, target.isdigit()):
        case ("1", ">&", True):
            return False
        case ("1", _, _):
            return True
        case _:
            return False
