"""PreToolUse hook: block a read that puts over MAX_BYTES into context.

Reads the hook input from stdin. A Bash command whose `cat` and `git show
rev:path` operands total over MAX_BYTES, or a Read with no `limit` of a text
file over MAX_BYTES, exits 2, which makes Claude Code block the call and show
stderr to the model. Only Bash reads whose output reaches the screen count: one
redirected to a file or piped into another command dumps nothing into context,
and heredoc bodies are data, not commands. Files agents are told to read in
full are exempt: instruction files and anything in a skill. What is exempt is
decided on the path as typed, normalised but with links unfollowed: the guard
stops accidents, it is not a security boundary. Everything else exits 0,
including any input this script does not understand: the guard fails open.
"""

import glob
import os
import re
import subprocess
import sys
from collections.abc import Iterator
from pathlib import Path

from bash_commands import Sink, simple_commands
from hook_event import Json, ReadCall, parse_bash_call, parse_json, parse_read_call

MAX_BYTES = 16 * 1024
BASH_HINT = (
    "Blocked: this reads {size} bytes in one command. "
    "grep -n first, then read the range with sed -n."
)
READ_HINT = (
    "Blocked: this Read takes the whole {size} byte file. "
    "grep -n first, then Read with offset and limit."
)
INSTRUCTIONS = {"AGENTS.md", "CLAUDE.md", "SKILL.md", "factory-instructions.md"}
SKILL_FILE = re.compile(r"(?:.*/)?skills/[^/]+/.+")
# The Read tool renders these for the model: their bytes are not text in context.
MEDIA = {".gif", ".jpeg", ".jpg", ".pdf", ".png", ".webp"}


def main() -> None:
    try:
        event = parse_json(sys.stdin.read())
        cwd = working_directory(event)
        match event:
            case {"tool_name": "Read"}:
                size = read_tool_size(parse_read_call(event), cwd)
                hint = READ_HINT
            case _:
                size = sum(read_sizes(parse_bash_call(event).command, cwd))
                hint = BASH_HINT
    except Exception:  # noqa: BLE001 - any failure must let the call through
        sys.exit(0)

    if size > MAX_BYTES:
        print(hint.format(size=size), file=sys.stderr)
        sys.exit(2)


def working_directory(event: Json) -> str:
    match event:
        case {"cwd": str(cwd)} if cwd:
            return cwd
        case _:
            return str(Path.cwd())


def read_tool_size(call: ReadCall, cwd: str) -> int:
    """What a Read tool call puts into context, 0 where it is bounded or exempt."""
    path = resolve(cwd, call.file_path)
    # Not Path.suffix: at Python 3.13 it calls a file named `..png` an image.
    media = os.path.splitext(path)[1].lower() in MEDIA  # noqa: PTH122
    if media or call.bounded or is_exempt(path) or not is_file(path):
        return 0
    return Path(path).stat().st_size


def resolve(cwd: str, path: str) -> str:
    """Normalised, with `..` collapsed lexically: links stay unfollowed."""
    return os.path.normpath(Path(cwd) / expand_home(path))


def expand_home(path: str) -> str:
    """An unknown `~name` stays as typed, one more path that names no file.

    Path.expanduser raises on it instead, and that would fail the call open.
    """
    return os.path.expanduser(path)  # noqa: PTH111


def is_file(path: str) -> bool:
    """False for any path that cannot be stat'ed.

    Path.is_file raises on a denied or over-long path, which would fail open.
    """
    return os.path.isfile(path)  # noqa: PTH113


def is_exempt(path: str) -> bool:
    """Whether agents are told to read this normalised path in full."""
    return Path(path).name in INSTRUCTIONS or bool(SKILL_FILE.fullmatch(path))


def read_sizes(command: str, cwd: str) -> Iterator[int]:
    """The size of every file the command reads, skipping exempt and unknown ones.

    A `cd` moves the directory for every later command, whatever operator
    joins them. A `cd` that would fail leaves a directory that does not exist,
    so nothing after it is found or counted: the guard fails open.
    """
    for simple in simple_commands(command):
        match (simple.words, simple.sink):
            case (["cd"], _):
                cwd = expand_home("~")
            case (["cd", target], _):
                cwd = resolve(cwd, target)
            case (["cat", *args], Sink.SCREEN):
                for pattern in operands(args):
                    yield from file_sizes(cwd, pattern)
            case (["git", "-C", repo, "show", *args], Sink.SCREEN):
                yield from blob_sizes(str(Path(cwd) / repo), operands(args))
            case (["git", "show", *args], Sink.SCREEN):
                yield from blob_sizes(cwd, operands(args))
            case _:
                pass


def operands(args: list[str]) -> list[str]:
    return [a for a in args if not a.startswith("-")]


def file_sizes(cwd: str, pattern: str) -> Iterator[int]:
    """One size per file the operand names: a glob may name several."""
    path = resolve(cwd, pattern)
    # Path.glob refuses the absolute pattern `resolve` returns.
    for found in glob.glob(path) or [path]:  # noqa: PTH207
        if is_file(found) and not is_exempt(found):
            yield Path(found).stat().st_size


def blob_sizes(repo: str, args: list[str]) -> Iterator[int]:
    for arg in args:
        match arg.partition(":"):
            case (rev, ":", path) if path and not is_exempt(os.path.normpath(path)):
                yield object_size(repo, f"{rev}:{path}")
            case _:
                pass


def object_size(repo: str, spec: str) -> int:
    """The blob's size, 0 for one git cannot find: the guard fails open."""
    result = subprocess.run(
        ["@git@", "-C", repo, "cat-file", "-s", spec],
        capture_output=True,
        text=True,
        check=False,
    )
    return int(result.stdout) if result.returncode == 0 else 0


if __name__ == "__main__":
    main()
