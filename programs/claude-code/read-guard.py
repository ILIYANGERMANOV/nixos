"""PreToolUse hook: block a Bash command that dumps several large files at once.

Reads the hook input from stdin. A command whose `cat` and `git show rev:path`
operands name two or more files totalling over MAX_BYTES exits 2, which makes
Claude Code block the call and show stderr to the model. Relative operands
resolve against the directory the last `cd` in the chain moved to. Everything
else exits 0, including any input this script does not understand: the guard
fails open.
"""

import glob
import json
import os
import shlex
import subprocess
import sys
from collections.abc import Iterator

MAX_BYTES = 8 * 1024
HINT = (
    "Blocked: this reads {count} files totalling {size} bytes in one command. "
    "grep -n first, then read the range with sed -n; "
    "read one large file per command."
)
OPERATORS = set(";&|()<>")


def main() -> None:
    try:
        event = json.load(sys.stdin)
        command = event["tool_input"]["command"]
        cwd = event.get("cwd") or os.getcwd()
        sizes = [size for size in read_sizes(command, cwd) if size is not None]
    except Exception:
        sys.exit(0)

    total = sum(sizes)
    match (len(sizes) > 1, total > MAX_BYTES):
        case (True, True):
            print(HINT.format(count=len(sizes), size=total), file=sys.stderr)
            sys.exit(2)
        case _:
            sys.exit(0)


def read_sizes(command: str, cwd: str) -> Iterator[int | None]:
    """The size of every file the command reads, None where it is unknown.

    A `cd` moves the directory for every later command, whatever operator
    joins them. A `cd` that would fail leaves a directory that does not exist,
    so nothing after it is found or counted: the guard fails open.
    """
    for words in simple_commands(command):
        match words:
            case ["cd"]:
                cwd = os.path.expanduser("~")
            case ["cd", target]:
                cwd = os.path.join(cwd, os.path.expanduser(target))
            case ["cat", *args]:
                for pattern in operands(args):
                    yield from file_sizes(cwd, pattern)
            case ["git", "-C", repo, "show", *args]:
                yield from blob_sizes(os.path.join(cwd, repo), operands(args))
            case ["git", "show", *args]:
                yield from blob_sizes(cwd, operands(args))
            case _:
                pass


def simple_commands(command: str) -> Iterator[list[str]]:
    """The words of each simple command, split at shell operators.

    A redirection target starts a command of its own, which is harmless: only
    a command starting with cat or git is ever sized.
    """
    lexer = shlex.shlex(
        command.replace("\n", " ; "), posix=True, punctuation_chars=True
    )
    lexer.whitespace_split = True
    words = []
    for token in lexer:
        if set(token) <= OPERATORS:
            yield words
            words = []
        else:
            words.append(token)
    yield words


def operands(args: list[str]) -> list[str]:
    return [a for a in args if not a.startswith("-")]


def file_sizes(cwd: str, pattern: str) -> Iterator[int | None]:
    """One size per file the operand names: a glob may name several."""
    path = os.path.join(cwd, pattern)
    for found in glob.glob(path) or [path]:
        yield os.path.getsize(found) if os.path.isfile(found) else None


def blob_sizes(repo: str, args: list[str]) -> Iterator[int | None]:
    for arg in args:
        match arg.partition(":"):
            case (rev, ":", path) if path:
                yield object_size(repo, f"{rev}:{path}")
            case _:
                pass


def object_size(repo: str, spec: str) -> int | None:
    result = subprocess.run(
        ["@git@", "-C", repo, "cat-file", "-s", spec],
        capture_output=True,
        text=True,
    )
    return int(result.stdout) if result.returncode == 0 else None


if __name__ == "__main__":
    main()
