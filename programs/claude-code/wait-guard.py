"""PreToolUse hook: block a foreground Bash call that waits.

Reads the hook input from stdin. A call not sent with run_in_background whose
command sleeps MIN_SLEEP seconds or more in one go, or loops with `until` or
`while` around a `sleep`, exits 2, which makes Claude Code block the call and
show stderr to the model. Only commands count, so `echo "sleep 30"` and a
heredoc body naming one are allowed. Everything else exits 0, including any
input this script does not understand: the guard fails open.
"""

import json
import re
import sys
from collections.abc import Iterator

from bash_commands import simple_commands

MIN_SLEEP = 10
HINT = (
    "Blocked: this command waits in the foreground. Run a long command with "
    "run_in_background and wait for its task notification, never polling its "
    "output; to wait for a condition, use the Monitor tool."
)
# Words that may precede a command in a compound statement.
PREFIXES = {"do", "then", "else", "{", "!", "time"}
LOOPS = {"until", "while"}
# GNU sleep: a number with an optional unit suffix.
DURATION = re.compile(r"(\d+(?:\.\d*)?|\.\d+)([smhd]?)")
UNIT_SECONDS = {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}


def main() -> None:
    try:
        event = json.load(sys.stdin)
        tool_input = event["tool_input"]
        background = tool_input.get("run_in_background") is True
        waits = is_wait(tool_input["command"])
    except Exception:
        sys.exit(0)

    match (background, waits):
        case (False, True):
            print(HINT, file=sys.stderr)
            sys.exit(2)
        case _:
            sys.exit(0)


def is_wait(command: str) -> bool:
    commands = [words for words in leading_words(command) if words]
    sleeps = [seconds(args) for name, *args in commands if name == "sleep"]
    loops = any(name in LOOPS for name, *_ in commands)
    return any(s >= MIN_SLEEP for s in sleeps) or (loops and bool(sleeps))


def leading_words(command: str) -> Iterator[list[str]]:
    """Each simple command's words, with the compound keywords before it dropped."""
    for simple in simple_commands(command):
        words = simple.words
        while words and words[0] in PREFIXES:
            words = words[1:]
        yield words


def seconds(args: list[str]) -> float:
    """GNU sleep's total: it sums its operands. An unparsed one counts as 0."""
    return sum(duration(arg) for arg in args)


def duration(arg: str) -> float:
    match DURATION.fullmatch(arg):
        case None:
            return 0
        case found:
            return float(found.group(1)) * UNIT_SECONDS[found.group(2)]


if __name__ == "__main__":
    main()
