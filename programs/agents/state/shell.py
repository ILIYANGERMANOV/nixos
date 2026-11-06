"""The effects: the notes pointer, the log on disk, the clock, the session id
and git. It reads, lets the pure modules decide, then writes."""

import os
import subprocess
import sys
from dataclasses import replace
from datetime import UTC, datetime
from pathlib import Path

from cli import (
    BriefCmd,
    Command,
    HandbackCmd,
    Init,
    Next,
    Override,
    RecordCmd,
    Show,
    parse_record,
    usage,
)
from codec import BadFieldError, Line, encode_line, parse_log, replay
from core import (
    GitFacts,
    NoFacts,
    advise,
    brief,
    parse_handback,
    record,
    render_advice,
    show,
)
from model import Event, Failure, Overridden, Started, State, name_of

# ---- The shell ------------------------------------------------------------------

LOG = "events.jsonl"
# Per worktree, so each run in its own worktree finds its own log.
POINTER = "state-notes"
LOCKFILES = ("flake.lock", "package-lock.json", "pnpm-lock.yaml")


class GitError(Exception):
    """A git command that should not fail did: an outage, not a bad ref."""


def execute(command: Command, cwd: Path, stdin: str | None) -> str | Failure:  # noqa: C901, PLR0911, PLR0912 - one arm per command
    match locate(cwd):
        case Failure() as failure:
            return failure
        case git_dir:
            pass
    if isinstance(command, Init):
        return init(git_dir, command, head_of(cwd))
    match load(git_dir):
        case Failure() as failure:
            return failure
        case (log, lines, state):
            pass
    match command:
        case RecordCmd(args=args):
            match parse_record(args, head_of(cwd)):
                case Failure() as failure:
                    return failure
                case event:
                    return append(log, lines, state, (event,), cwd)
        case HandbackCmd(role=role, options=options):
            text = sys.stdin.read() if stdin is None else stdin
            match parse_handback(role, text, options, head_of(cwd)):
                case Failure() as failure:
                    return failure
                case events:
                    return append(log, lines, state, events, cwd)
        case Override(to=to, why=why):
            return append(log, lines, state, (Overridden(to, why),), cwd)
        case Next():
            facts = NoFacts() if state.base is None else git_facts(cwd, state.base)
            return render_advice(advise(state, facts))
        case BriefCmd(role=role):
            return brief(role, state, toplevel(cwd))
        case Show():
            return show(state)


def init(git_dir: Path, command: Init, head: str | None) -> str | Failure:
    """Idempotent: a log that holds its `started` line gets nothing more."""
    notes = command.notes.absolute()
    log = notes / LOG
    notes.mkdir(parents=True, exist_ok=True)
    _ = (git_dir / POINTER).write_text(f"{notes}\n")
    if log.exists() and log.read_text():
        match read_log(log):
            case Failure() as failure:
                return failure
            case _:
                return f"{log}\nstarted: already\n"
    line = Line(1, now(), head, session(), Started(str(notes), command.delegated))
    with log.open("a") as file:
        _ = file.write(encode_line(line))
    return f"{log}\nstarted: yes\n"


def load(git_dir: Path) -> tuple[Path, list[Line], State] | Failure:
    pointer = git_dir / POINTER
    if not pointer.exists():
        return Failure(
            "state: no run in this worktree",
            "state init --notes /tmp/engineer-<owner>-<repo>-<slug>",
            2,
        )
    log = Path(pointer.read_text().strip()) / LOG
    match read_log(log):
        case Failure() as failure:
            return failure
        case lines, state:
            return log, lines, state


def read_log(log: Path) -> tuple[list[Line], State] | Failure:
    """The log's lines and the state they replay to; no log is an empty one."""
    match parse_log(log.read_text() if log.exists() else "", log):
        case Failure() as failure:
            return failure
        case lines:
            pass
    match replay(lines, log):
        case Failure() as failure:
            return failure
        case state:
            return lines, state


def append(
    log: Path, lines: list[Line], state: State, events: tuple[Event, ...], cwd: Path
) -> str | Failure:
    match record(state, events):
        case Failure() as failure:
            return replace(failure, message=f"state record: {failure.message}")
        case appended, reached:
            pass
    head, ts, sess = head_of(cwd), now(), session()
    new = [
        Line(len(lines) + i, ts, head, sess, e) for i, e in enumerate(appended, start=1)
    ]
    try:
        text = "".join(encode_line(line) for line in new)
    except BadFieldError as error:  # a hand-back line with nothing after its token
        return usage(f"record: {error}", "give the hand-back's line 1 its text")
    # One write per call, so lines of one call never interleave with another's.
    with log.open("a") as file:
        _ = file.write(text)
    return "".join(
        f"recorded {line.seq} {name_of(line.event)} -> {reached.step}\n" for line in new
    )


def git_facts(cwd: Path, base: str) -> GitFacts:
    out = git(cwd, "diff", "--numstat", "--summary", f"origin/{base}...HEAD")
    return parse_numstat(out)


def parse_numstat(out: str) -> GitFacts:
    """`git diff --numstat --summary`: lockfiles and binary rows add no lines."""
    lines, skills = 0, "none"
    for row in out.splitlines():
        parts = row.split("\t")
        match parts:
            case [added, deleted, path] if added.isdigit() and deleted.isdigit():
                if not is_lockfile(path):
                    lines += int(added) + int(deleted)
                if path.endswith("SKILL.md") and skills == "none":
                    skills = "changed"
            case [summary] if summary.strip().startswith(
                "create mode"
            ) and summary.endswith("SKILL.md"):
                skills = "new"
            case _:
                pass
    return GitFacts(lines, skills)


def is_lockfile(path: str) -> bool:
    name = path.rsplit("/", 1)[-1]
    return name in LOCKFILES or name.endswith(".lock")


def locate(cwd: Path) -> Path | Failure:
    found = run_git(cwd, "rev-parse", "--absolute-git-dir")
    if found.returncode != 0:
        return Failure(
            f"state: not inside a git work tree (cwd {cwd})",
            "cd <worktree>; state keeps one run per worktree",
            2,
        )
    return Path(found.stdout.strip())


def head_of(cwd: Path) -> str | None:
    found = run_git(cwd, "rev-parse", "--verify", "--quiet", "HEAD")
    return found.stdout.strip() or None if found.returncode == 0 else None


def toplevel(cwd: Path) -> str:
    return git(cwd, "rev-parse", "--show-toplevel").strip()


def now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def session() -> str | None:
    """The runner's session id, when it exports one as STATE_SESSION."""
    return os.environ.get("STATE_SESSION") or None


def git(cwd: Path, *args: str) -> str:
    done = run_git(cwd, *args)
    if done.returncode != 0:
        raise GitError(f"git {' '.join(args)}: {done.stderr.strip()}")
    return done.stdout


def run_git(cwd: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args], cwd=cwd, check=False, capture_output=True, text=True
    )
