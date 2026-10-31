"""PreToolUse hook: block a foreground Bash call that waits.

Reads the hook input from stdin. A call not sent with run_in_background whose
command sleeps MIN_SLEEP seconds or more in one go, loops with `until` or
`while` around a `sleep`, or follows a file with `tail -f`, exits 2, which makes
Claude Code block the call and show stderr to the model. A wait counts behind
`bash -c`, `sh -c`, `timeout`, `nix develop -c` and an assignment prefix, unless
a `timeout` under MIN_SLEEP bounds it. A `tail -f` sent to the background with
`&` follows beside the call instead of holding it. Only commands count, so
`echo "sleep 30"` and a heredoc body naming one are allowed. Everything else
exits 0, including any input this script does not understand: the guard fails
open.

A subagent never waits on CI: its caller does. In a subagent, backgrounded or
not, the guard also blocks `gh pr checks --watch`, `gh run watch`, any CI read
in a loop, and a status read (`gh pr checks`, `gh run view`, `gh run list`) the
agent already made, in this command or an earlier one of its transcript. One
status read stays allowed, because review agents read CI as evidence, and so
does a log read outside a loop: `gh run view --log` of a finished run returns
the same log, and only the filter after it changes. A CI read inside a `$(...)`
is one word to the splitter and goes unseen.
"""

import json
import re
import sys
from collections.abc import Callable, Iterable, Iterator
from enum import Enum, auto
from itertools import dropwhile

from bash_commands import simple_commands
from transcripts import own_transcript, parse_line

MIN_SLEEP = 10
HINT = (
    "Blocked: this command waits in the foreground. Run a long command with "
    "run_in_background and wait for its task notification, never polling its "
    "output; to wait for a condition, use the Monitor tool. A subagent's "
    "background task dies at its hand-back, so a subagent runs the long command "
    "itself in the foreground with timeout 600000."
)
CI_HINT = (
    "Blocked: a subagent never waits on CI. Hand back now and your caller waits "
    "on the PR. One plain `gh pr checks <n>` read is allowed."
)
LOOPS = {"until", "while"}
# `do` is the only keyword a `for` loop leaves on the commands in its body.
LOOP_BODY = LOOPS | {"do"}
# Words that may precede a command in a compound statement.
KEYWORDS = {"do", "then", "else", "elif", "if", "{", "!", "time"} | LOOPS
# GNU sleep: a number with an optional unit suffix.
DURATION = re.compile(r"(\d+(?:\.\d*)?|\.\d+)([smhd]?)")
UNIT_SECONDS = {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}
ASSIGNMENT = re.compile(r"[A-Za-z_]\w*=.*")
SHELLS = {"bash", "sh"}
SHELL_COMMAND_FLAG = re.compile(r"-[a-z]*c[a-z]*")
# GNU tail: `-f` or `-F`, alone or after flags that take no value.
TAIL_FOLLOW = re.compile(r"-[\dqvz]*[fF]\w*|--follow(=.*)?")


def main() -> None:
    try:
        event = json.load(sys.stdin)
        tool_input = event["tool_input"]
        background = tool_input.get("run_in_background") is True
        waits = is_wait(tool_input["command"])
        polls = "agent_id" in event and polls_ci(
            tool_input["command"], earlier_commands(event)
        )
    except Exception:
        sys.exit(0)

    match (polls, background, waits):
        case (True, _, _):
            print(CI_HINT, file=sys.stderr)
            sys.exit(2)
        case (False, False, True):
            print(HINT, file=sys.stderr)
            sys.exit(2)
        case _:
            sys.exit(0)


class CiRead(Enum):
    NONE = auto()
    STATUS = auto()
    LOG = auto()
    WATCH = auto()


def polls_ci(command: str, earlier: Iterable[str]) -> bool:
    """Whether a subagent's command waits on CI. Only a status read reads earlier."""
    commands = list(split_keywords(command))
    kinds = [ci_read(words) for _, words in commands]
    looped = any(
        LOOP_BODY & set(keywords) and kind is not CiRead.NONE
        for (keywords, _), kind in zip(commands, kinds)
    )
    statuses = [
        status_key(words)
        for (_, words), kind in zip(commands, kinds)
        if kind is CiRead.STATUS
    ]
    return any((
        CiRead.WATCH in kinds,
        looped,
        len(set(statuses)) < len(statuses),
        bool(statuses) and not status_keys(earlier).isdisjoint(statuses),
    ))


def ci_read(words: list[str]) -> CiRead:
    match words:
        case ["gh", "run", "watch", *_]:
            return CiRead.WATCH
        case ["gh", "pr", "checks", *args]:
            return CiRead.WATCH if "--watch" in args else CiRead.STATUS
        case ["gh", "run", "view", *args]:
            logs = any(arg.startswith("--log") for arg in args)
            return CiRead.LOG if logs else CiRead.STATUS
        case ["gh", "run", "list", *_]:
            return CiRead.STATUS
        case _:
            return CiRead.NONE


def status_key(words: list[str]) -> tuple[str, ...]:
    """What a status read asks about: its subcommand and first operand."""
    operands = [word for word in words[3:] if not word.startswith("-")]
    return (*words[:3], *operands[:1])


def status_keys(commands: Iterable[str]) -> set[tuple[str, ...]]:
    return {
        status_key(words)
        for command in commands
        for _, words in parsed(command)
        if ci_read(words) is CiRead.STATUS
    }


def parsed(command: str) -> list[tuple[list[str], list[str]]]:
    """A command's simple commands, none for one that does not parse."""
    try:
        return list(split_keywords(command))
    except ValueError:
        return []


def earlier_commands(event: dict) -> Iterator[str]:
    """The agent's Bash commands so far, without the call under judgement."""
    with own_transcript(event).open("rb") as transcript:
        for line in transcript:
            match parse_line(line):
                case {"type": "assistant", "message": {"content": list(blocks)}}:
                    yield from bash_commands(blocks, event.get("tool_use_id"))
                case _:
                    pass


def bash_commands(blocks: list, skip: str | None) -> Iterator[str]:
    for block in blocks:
        match block:
            case {
                "type": "tool_use",
                "name": "Bash",
                "id": call,
                "input": {"command": command},
            } if call != skip:
                yield command
            case _:
                pass


def is_wait(command: str) -> bool:
    commands = list(split_keywords(command))
    loops = any(LOOPS & set(keywords) for keywords, _ in commands)
    sleeps = [seconds(words[1:]) for _, words in commands if words[:1] == ["sleep"]]
    follows = any(is_tail_follow(words) for _, words in commands)
    return any(s >= MIN_SLEEP for s in sleeps) or (loops and bool(sleeps)) or follows


def split_keywords(command: str) -> Iterator[tuple[list[str], list[str]]]:
    """Each simple command as the compound keywords before it and its own words.

    The script of a `bash -c` stands in for the shell, so what it runs counts,
    under the keywords before that shell: `until bash -c ...` is still a loop.
    A script that does not parse stands as the shell itself, so it cannot hide
    what the commands around it do.
    """
    for simple in simple_commands(command):
        words = simple.words
        count = next(
            (i for i, word in enumerate(words) if word not in KEYWORDS), len(words)
        )
        keywords, inner = words[:count], unwrap(words[count:])
        if simple.background and is_tail_follow(inner):
            continue
        match shell_script(inner):
            case None:
                yield keywords, inner
            case script:
                for script_keywords, script_words in script_commands(script, inner):
                    yield keywords + script_keywords, script_words


def script_commands(script: str, shell: list[str]) -> list[tuple[list[str], list[str]]]:
    return parsed(script) or [([], shell)]


def unwrap(words: list[str]) -> list[str]:
    """The command a wrapper runs. A timeout under MIN_SLEEP hides no wait."""
    match words:
        case [word, *rest] if ASSIGNMENT.fullmatch(word):
            return unwrap(rest)
        case ["timeout", *rest]:
            match list(dropwhile(lambda arg: arg.startswith("-"), rest)):
                case [limit, *inner] if duration(limit) >= MIN_SLEEP:
                    return unwrap(inner)
                case _:
                    return []
        case ["nix", "develop", *rest]:
            return unwrap(after(lambda arg: arg == "-c", rest))
        case _:
            return words


def shell_script(words: list[str]) -> str | None:
    match words:
        case [shell, *args] if shell in SHELLS:
            match after(SHELL_COMMAND_FLAG.fullmatch, args):
                case [script, *_]:
                    return script
                case []:
                    return None
        case _:
            return None


def after(is_flag: Callable[[str], object], args: list[str]) -> list[str]:
    """What follows the first flag, nothing without one."""
    return list(dropwhile(lambda arg: not is_flag(arg), args))[1:]


def is_tail_follow(words: list[str]) -> bool:
    return words[:1] == ["tail"] and any(TAIL_FOLLOW.fullmatch(arg) for arg in words[1:])


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
