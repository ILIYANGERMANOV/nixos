"""PreToolUse hook: block a read that puts over MAX_BYTES into context.

Reads the hook input from stdin. A Bash command whose `cat` and `git show
rev:path` operands total over MAX_BYTES, or a Read with no `limit` of a text
file over MAX_BYTES, exits 2, which makes Claude Code block the call and show
stderr to the model. Only Bash reads whose output reaches the screen count: one
redirected to a file or piped into another command dumps nothing into context,
and heredoc bodies are data, not commands. Files agents are told to read in
full are exempt: instruction files and anything in a skill. What is exempt is
decided on the path as typed, normalised but with links unfollowed: the guard
stops accidents, it is not a security boundary. Relative operands resolve
against the directory the last `cd` in the chain moved to. Everything else
exits 0, including any input this script does not understand: the guard fails
open.
"""

import glob
import json
import os
import re
import subprocess
import sys
from collections.abc import Iterator

from bash_commands import Sink, simple_commands

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
        event = json.load(sys.stdin)
        tool_input = event["tool_input"]
        cwd = event.get("cwd") or os.getcwd()
        match event.get("tool_name"):
            case "Read":
                size, hint = read_tool_size(tool_input, cwd), READ_HINT
            case _:
                size, hint = sum(read_sizes(tool_input["command"], cwd)), BASH_HINT
    except Exception:
        sys.exit(0)

    if size > MAX_BYTES:
        print(hint.format(size=size), file=sys.stderr)
        sys.exit(2)


def read_tool_size(tool_input: dict, cwd: str) -> int:
    """What a Read tool call puts into context, 0 where it is bounded or exempt."""
    path = resolve(cwd, tool_input["file_path"])
    media = os.path.splitext(path)[1].lower() in MEDIA
    bounded = tool_input.get("limit") is not None
    if media or bounded or is_exempt(path) or not os.path.isfile(path):
        return 0
    return os.path.getsize(path)


def read_sizes(command: str, cwd: str) -> Iterator[int]:
    """The size of every file the command reads, skipping exempt and unknown ones.

    A `cd` moves the directory for every later command, whatever operator
    joins them. A `cd` that would fail leaves a directory that does not exist,
    so nothing after it is found or counted: the guard fails open.
    """
    for simple in simple_commands(command):
        match (simple.words, simple.sink):
            case (["cd"], _):
                cwd = os.path.expanduser("~")
            case (["cd", target], _):
                cwd = os.path.join(cwd, os.path.expanduser(target))
            case (["cat", *args], Sink.SCREEN):
                for pattern in operands(args):
                    yield from file_sizes(cwd, pattern)
            case (["git", "-C", repo, "show", *args], Sink.SCREEN):
                yield from blob_sizes(os.path.join(cwd, repo), operands(args))
            case (["git", "show", *args], Sink.SCREEN):
                yield from blob_sizes(cwd, operands(args))
            case _:
                pass


def operands(args: list[str]) -> list[str]:
    return [a for a in args if not a.startswith("-")]


def file_sizes(cwd: str, pattern: str) -> Iterator[int]:
    """One size per file the operand names: a glob may name several."""
    path = resolve(cwd, pattern)
    for found in glob.glob(path) or [path]:
        if os.path.isfile(found) and not is_exempt(found):
            yield os.path.getsize(found)


def resolve(cwd: str, path: str) -> str:
    return os.path.normpath(os.path.join(cwd, os.path.expanduser(path)))


def is_exempt(path: str) -> bool:
    """Whether agents are told to read this normalised path in full."""
    return os.path.basename(path) in INSTRUCTIONS or bool(SKILL_FILE.fullmatch(path))


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
    )
    return int(result.stdout) if result.returncode == 0 else 0


if __name__ == "__main__":
    main()
