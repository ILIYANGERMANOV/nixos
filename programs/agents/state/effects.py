"""The effects: the notes pointer, the log on disk, the clock, the session id,
git and the PR on GitHub. It reads, lets the pure modules decide, then writes."""

import json
import os
import subprocess
import sys
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from pathlib import Path
from typing import cast

from state.cli import (
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
from state.codec import (
    PR_URL_SHAPE,
    BadFieldError,
    Line,
    encode_line,
    parse_log,
    pick,
    replay,
)
from state.core import (
    PR_STATES,
    Accepted,
    Facts,
    GitFacts,
    NoFacts,
    NoPr,
    Pr,
    PrRead,
    Refusal,
    Unavailable,
    advise,
    brief,
    decide,
    off_branch,
    parse_handback,
    pr_closed,
    pr_to_read,
    record,
    render_advice,
    show,
    synced,
    warning,
)
from state.model import Event, Failure, Json, Overridden, Started, State, name_of

# ---- The shell ------------------------------------------------------------------

LOG = "events.jsonl"
# Per worktree, so each run in its own worktree finds its own log.
POINTER = "state-notes"
LOCKFILES = ("flake.lock", "package-lock.json", "pnpm-lock.yaml")
PR_FIELDS = "url,baseRefName,headRefName,isDraft,state"
# Seconds: a hook waits on it, and an offline `gh` should not stall a session.
GH_TIMEOUT = 10
# What `gh pr view` prints, exit 1, for a branch with no PR (gh 2.103.3).
NO_PR = "no pull requests found for branch"


class GitError(Exception):
    """A git command that should not fail did: an outage, not a bad ref."""


@dataclass(frozen=True, slots=True)
class Loaded:
    """A worktree's run, synced from GitHub: its log, the lines read, the state
    they fold to and what the sync recorded or why it was skipped."""

    log: Path
    lines: list[Line]
    state: State
    told: str = ""


@dataclass(frozen=True, slots=True)
class Quiet:
    """A run the hooks stay silent on, and why; `state show` still shows it."""

    run: Loaded
    why: str


def execute(command: Command, cwd: Path, stdin: str | None) -> str | Failure:  # noqa: C901, PLR0911 - one arm per command
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
                    parsed: tuple[Event, ...] | Failure = failure
                case event:
                    parsed = (event,)
            return append(log, lines, state, parsed, cwd)
        case HandbackCmd(role=role, options=options):
            text = sys.stdin.read() if stdin is None else stdin
            parsed = parse_handback(role, text, options, head_of(cwd))
            return append(log, lines, state, parsed, cwd)
        case Override(to=to, why=why):
            return append(log, lines, state, (Overridden(to, why),), cwd)
        case Next() | Show():
            return viewed(command, git_dir, cwd)
        case BriefCmd(role=role):
            return brief(role, state, toplevel(cwd))


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
    log: Path,
    lines: list[Line],
    state: State,
    parsed: tuple[Event, ...] | Failure,
    cwd: Path,
) -> str | Failure:
    """What a command or hook records, a refusal included: it is stored too."""
    match decide(state, parsed):
        case Accepted(append=appended, reached=reached):
            match write(log, lines, appended, cwd):
                case Failure() as failure:
                    return failure
                case new:
                    return recorded(new, reached)
        case Refusal(refused=refused, reply=reply):
            match write(log, lines, (refused,), cwd):
                case Failure() as failure:
                    return failure
                case _:
                    return reply


def write(
    log: Path, lines: list[Line], appended: tuple[Event, ...], cwd: Path
) -> list[Line] | Failure:
    """The lines appended for `appended`, decided already."""
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
    return new


def recorded(new: list[Line], reached: State) -> str:
    return "".join(
        f"recorded {line.seq} {name_of(line.event)} -> {reached.step}\n" for line in new
    )


def viewed(command: Next | Show, git_dir: Path, cwd: Path) -> str | Failure:
    """`state next` and `state show`, synced from GitHub first, with why the
    hooks stay silent when they do."""
    match open_run(git_dir, cwd):
        case Failure() as failure:
            return failure
        case Quiet(run=run, why=why):
            silent = f"state hooks: silent - {why}\n"
        case Loaded() as run:
            silent = ""
    match command:
        case Next():
            view = next_advice(run.state, cwd)
        case Show():
            view = show(run.state)
    return f"{run.told}{silent}{view}"


def open_run(git_dir: Path, cwd: Path) -> Loaded | Quiet | Failure:
    """The run, synced from GitHub, told first of a refusal pending before the
    sync: a sync event that clears it still shows it once."""
    match load(git_dir):
        case Failure() as failure:
            return failure
        case log, lines, state:
            warn = warning(state)
    match synced_run(Loaded(log, lines, state), cwd):
        case Loaded() as run:
            return replace(run, told=f"{warn}{run.told}")
        case Quiet(run=run) as quiet:
            return replace(quiet, run=replace(run, told=f"{warn}{run.told}"))


def synced_run(run: Loaded, cwd: Path) -> Loaded | Quiet:
    """Cheapest check first: a Done run or one bound to another branch is quiet
    before any `gh` call; one whose drafted PR is merged or closed after it."""
    state = run.state
    branch = branch_of(cwd)
    match off_branch(state, branch), pr_to_read(state):
        case str(why), _:
            return Quiet(run, why)
        case None, None:
            return run
        case None, args:
            pass
    match gh_pr_view(cwd, args):
        case Unavailable(why=why):
            return replace(run, told=f"PR sync skipped - {why}\n")
        case NoPr():
            return run
        case Pr() as pr:
            run = sync(run, synced(state, pr), cwd)
    why = pr_closed(run.state, pr) or off_branch(run.state, branch)
    return run if why is None else Quiet(run, why)


def sync(run: Loaded, events: tuple[Event, ...], cwd: Path) -> Loaded:
    """The run with what GitHub showed appended; no events append nothing. A
    sync the flow refuses is told, never stored: nobody asked for it."""
    match record(run.state, events):
        case Failure() as failure:
            return sync_failed(run, failure)
        case appended, reached:
            pass
    match write(run.log, run.lines, appended, cwd):
        case Failure() as failure:
            return sync_failed(run, failure)
        case new:
            return Loaded(run.log, [*run.lines, *new], reached, recorded(new, reached))


def sync_failed(run: Loaded, failure: Failure) -> Loaded:
    return replace(run, told=f"PR sync: {failure.message}\nfix: {failure.fix}\n")


def gh_pr_view(cwd: Path, args: tuple[str, ...]) -> PrRead:
    try:
        done = subprocess.run(
            ["gh", "pr", "view", *args, "--json", PR_FIELDS],
            cwd=cwd,
            check=False,
            capture_output=True,
            text=True,
            timeout=GH_TIMEOUT,
        )
    except FileNotFoundError:
        return Unavailable("gh is not on PATH")
    except subprocess.TimeoutExpired:
        return Unavailable(f"gh pr view timed out after {GH_TIMEOUT}s")
    return parse_pr_view(done.returncode, done.stdout, done.stderr)


def parse_pr_view(code: int, stdout: str, stderr: str) -> PrRead:
    """`gh pr view --json` PR_FIELDS: a PR, none for the branch, or why not."""
    match code:
        case 0:
            return parse_pr_json(stdout)
        case 1 if NO_PR in stderr:
            return NoPr()
        case _:
            first = next(iter(stderr.strip().splitlines()), f"exit {code}")
            return Unavailable(f"gh pr view: {first}")


def parse_pr_json(stdout: str) -> PrRead:
    try:
        found = cast("Json", json.loads(stdout))
    except json.JSONDecodeError:
        found = None
    match found:
        case {
            "url": str(url),
            "baseRefName": str(base),
            "headRefName": str(branch),
            "isDraft": bool(draft),
            "state": str(shown),
        } if PR_URL_SHAPE.fullmatch(url) and base and branch:
            pass
        case _:
            return Unavailable(f"gh pr view printed no PR: {stdout.strip()[:200]}")
    match pick(shown, PR_STATES):
        case None:
            return Unavailable(f"gh pr view: unknown PR state {shown}")
        case state:
            return Pr(url, base, branch, draft, state)


def next_advice(state: State, cwd: Path) -> str:
    """`state next`: the advised arrow, rendered."""
    return render_advice(advise(state, facts_of(state, cwd)))


def facts_of(state: State, cwd: Path) -> Facts:
    """What the advice reads from git: nothing until a draft names the base."""
    return NoFacts() if state.drafted is None else git_facts(cwd, state.drafted.base)


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
    return git_answer(cwd, "rev-parse", "--verify", "--quiet", "HEAD")


def branch_of(cwd: Path) -> str | None:
    """HEAD's branch; None when detached."""
    return git_answer(cwd, "symbolic-ref", "--quiet", "--short", "HEAD")


def git_answer(cwd: Path, *args: str) -> str | None:
    """A `--quiet` query's answer; None when git says there is none."""
    found = run_git(cwd, *args)
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
