"""`state`: record the engineer flow as events and advise the next arrow.

The only stored thing is `events.jsonl` in the run's notes directory, an
append-only JSON Lines log (https://jsonlines.org/). The current state is a
left fold over it, and the advice is a pure function of that state and the few
git facts the shell reads. It advises, never refuses: `state override` is the
way off an arrow. ADR 0014 holds the principles, ADR 0015 this program.
Stdlib only. This file is the entry point: it parses argv, runs the command
and turns the outcome into stdout, stderr and an exit code.
"""

import sys
from pathlib import Path

from cli import HELP, Help, Render, parse_args
from core import render
from effects import GitError, execute
from model import Failure


def main(argv: list[str], cwd: Path, stdin: str | None = None) -> int:  # noqa: PLR0911 - one arm per outcome
    parsed = parse_args(argv)
    match parsed:
        case Help():
            _ = sys.stdout.write(HELP)
            return 0
        case Render():
            _ = sys.stdout.write(render())
            return 0
        case Failure():
            return report(parsed)
        case _:
            try:
                result = execute(parsed, cwd, stdin)
            except GitError as error:
                return report(
                    Failure(
                        f"state: git failed - {error}",
                        "run that git command here to see why",
                        1,
                    )
                )
            except OSError as error:
                return report(
                    Failure(
                        f"state: cannot read or write the log - {error}",
                        "check the notes directory's path and access",
                        1,
                    )
                )
            match result:
                case str():
                    _ = sys.stdout.write(result)
                    return 0
                case Failure():
                    return report(result)


def report(failure: Failure) -> int:
    _ = sys.stderr.write(f"{failure.message}\nfix: {failure.fix}\n")
    return failure.code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], Path.cwd()))
