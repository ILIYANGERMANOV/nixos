"""May this be deleted? The decisions behind `factory-ctl free-disk` and factory-gc.

Reads facts, decides with pure functions from those facts to a `Decision`, prints
the paths to remove, NUL-terminated. The bash around it does the removing. A fact
that cannot be read is `Unknown`, and an `Unknown` always means Keep. Stdlib only.
"""

import os
import re
import stat
import subprocess
import sys
import time
from collections.abc import Collection, Iterable, Iterator
from dataclasses import dataclass
from enum import Enum, StrEnum, auto
from pathlib import Path, PurePath
from typing import NoReturn

DAY_SECONDS = 86_400.0
QA_RUN_QUIET_SECONDS = DAY_SECONDS
ROOT_STALE_SECONDS = 2 * DAY_SECONDS

# `nix develop --profile` makes <name>-N-link: its mtime is when the profile was
# made, not when it was last used, so age says nothing about it.
PROFILE_GENERATION = re.compile(r".*-[0-9].*-link", re.DOTALL)


@dataclass(frozen=True)
class Unknown:
    """A fact that could not be read, and which one."""

    fact: str


type Fact[T] = T | Unknown


class Policy(StrEnum):
    """Why something that is fully known stays."""

    MAIN_CHECKOUT = "the repository's main checkout"
    OUTSIDE_REPOSITORY = (
        "a worktree outside its repository belongs to a run, which removes it"
    )
    LOCKED = "the worktree is locked"
    LIVE_SESSION = "a live session works in it"
    LOCAL_WORK = "it holds work that is on no remote"
    KEEPS_BUILDS_FAST = "it keeps the next build fast"
    HIDDEN = "a hidden entry"
    GC_ROOT = "a symlink is a GC root, not a cache"
    NOT_A_RUN = "not a run directory"
    RECENT = "written too recently"
    GONE = "already gone"
    PROFILE_GENERATION = "a profile generation's mtime is not its last use"
    OUTSIDE_DIRECTORIES = "its result link is outside the temporary directories"
    NOT_A_LINK = "not a result link"
    SWAPPED_PARENT = "the path to its result link resolves elsewhere"
    OTHER_OWNER = "another account owns it"


type KeepReason = Policy | Unknown


@dataclass(frozen=True)
class Keep:
    path: PurePath
    reason: KeepReason


@dataclass(frozen=True)
class Remove:
    path: PurePath


type Decision = Keep | Remove


class Kind(Enum):
    FILE = auto()
    DIRECTORY = auto()
    SYMLINK = auto()


@dataclass(frozen=True)
class Stat:
    """What lstat says: the entry itself, never what a symlink points at."""

    kind: Kind
    mtime: float
    uid: int


@dataclass(frozen=True)
class Absent:
    pass


type Probe = Stat | Absent | Unknown


@dataclass(frozen=True)
class ListedWorktree:
    path: PurePath
    locked: bool


@dataclass(frozen=True)
class LocalWork:
    """Counts of what deleting a worktree would lose."""

    uncommitted: Fact[int]
    unpushed: Fact[int]


@dataclass(frozen=True)
class Worktree:
    path: PurePath
    repository: PurePath
    locked: bool
    local_work: LocalWork


@dataclass(frozen=True)
class QaRun:
    path: PurePath
    probe: Probe
    newest_write: Fact[float]


@dataclass(frozen=True)
class ResultLink:
    """The result link a GC root registers. Agents choose this path."""

    path: PurePath
    resolved_parent: Fact[PurePath]
    probe: Probe


@dataclass(frozen=True)
class GcRoot:
    entry: PurePath
    link: Fact[ResultLink]


def decide(path: PurePath, reasons: Iterable[KeepReason]) -> Decision:
    """Remove only when no reason to keep exists."""
    match next(iter(reasons), None):
        case None:
            return Remove(path)
        case reason:
            return Keep(path, reason)


def decide_worktree(
    worktree: Worktree, sessions: Fact[frozenset[PurePath]]
) -> Decision:
    """A secondary worktree whose deletion loses nothing goes.

    Only one inside its repository: a /qa run's or a /10x-engineer run's sits
    elsewhere, is clean and pushed while it waits, and its run removes it.
    """
    return decide(worktree.path, _worktree_keep_reasons(worktree, sessions))


def _worktree_keep_reasons(
    worktree: Worktree, sessions: Fact[frozenset[PurePath]]
) -> Iterator[KeepReason]:
    if worktree.path == worktree.repository:
        yield Policy.MAIN_CHECKOUT
    if not worktree.path.is_relative_to(worktree.repository):
        yield Policy.OUTSIDE_REPOSITORY
    if worktree.locked:
        yield Policy.LOCKED
    yield from _session_keep_reasons(worktree.path, sessions)
    yield from _local_work_keep_reasons(worktree.local_work)


def _session_keep_reasons(
    path: PurePath, sessions: Fact[frozenset[PurePath]]
) -> Iterator[KeepReason]:
    match sessions:
        case Unknown():
            yield sessions
        case frozenset():
            if any(cwd.is_relative_to(path) for cwd in sessions):
                yield Policy.LIVE_SESSION


def _local_work_keep_reasons(work: LocalWork) -> Iterator[KeepReason]:
    for count in (work.uncommitted, work.unpushed):
        match count:
            case Unknown():
                yield count
            case int():
                if count > 0:
                    yield Policy.LOCAL_WORK


def local_work_phrases(work: LocalWork) -> tuple[str, ...]:
    """What would be lost, one phrase each. Unknown is named, so it reads as a risk."""
    return (
        *_count_phrase(work.uncommitted, "uncommitted file(s)"),
        *_count_phrase(work.unpushed, "unpushed commit(s)"),
    )


def _count_phrase(count: Fact[int], noun: str) -> tuple[str, ...]:
    match count:
        case Unknown():
            return (f"unknown {noun}",)
        case int():
            return (f"{count} {noun}",) if count > 0 else ()


def decide_cache(
    path: PurePath, probe: Probe, kept_for_builds: Collection[PurePath]
) -> Decision:
    """Throwaway caches go. A symlink here is a dev shell's profile or a build's result link."""
    return decide(path, _cache_keep_reasons(path, probe, kept_for_builds))


def _cache_keep_reasons(
    path: PurePath, probe: Probe, kept_for_builds: Collection[PurePath]
) -> Iterator[KeepReason]:
    if path in kept_for_builds:
        yield Policy.KEEPS_BUILDS_FAST
    if path.name.startswith("."):
        yield Policy.HIDDEN
    match probe:
        case Absent():
            yield Policy.GONE
        case Unknown():
            yield probe
        case Stat(kind=Kind.SYMLINK):
            yield Policy.GC_ROOT
        case Stat():
            pass


def decide_qa_run(run: QaRun, now: float) -> Decision:
    """A run directory with nothing written for a day goes: its proof is on the PR."""
    return decide(run.path, _qa_run_keep_reasons(run, now))


def _qa_run_keep_reasons(run: QaRun, now: float) -> Iterator[KeepReason]:
    if run.path.name.startswith("."):
        yield Policy.HIDDEN
    match run.probe:
        case Absent():
            yield Policy.GONE
        case Unknown():
            yield run.probe
        case Stat(kind=Kind.DIRECTORY):
            pass
        case Stat():
            yield Policy.NOT_A_RUN
    match run.newest_write:
        case Unknown():
            yield run.newest_write
        case int() | float():
            if now - run.newest_write < QA_RUN_QUIET_SECONDS:
                yield Policy.RECENT


def decide_stale_root(
    root: GcRoot, directories: Collection[PurePath], now: float
) -> Decision:
    """A root whose result link is stale: its registration goes, the link stays."""
    match root.link:
        case Unknown():
            return Keep(root.entry, root.link)
        case ResultLink():
            return decide(root.entry, _stale_keep_reasons(root.link, directories, now))


def decide_own_stale_root(
    root: GcRoot, directories: Collection[PurePath], now: float, uid: int
) -> Decision:
    """The result link itself, for its owner: the only account that may delete it from /tmp."""
    match root.link:
        case Unknown():
            return Keep(root.entry, root.link)
        case ResultLink():
            reasons = (
                *_stale_keep_reasons(root.link, directories, now),
                *_foreign_owner(root.link.probe, uid),
            )
            return decide(root.link.path, reasons)


def _stale_keep_reasons(
    link: ResultLink, directories: Collection[PurePath], now: float
) -> Iterator[KeepReason]:
    if PROFILE_GENERATION.fullmatch(link.path.name):
        yield Policy.PROFILE_GENERATION
    if not any(link.path.parent.is_relative_to(directory) for directory in directories):
        yield Policy.OUTSIDE_DIRECTORIES
    yield from _link_keep_reasons(link.probe, now)
    # The path is the agent's to choose, so its parent may lead anywhere.
    match link.resolved_parent:
        case Unknown():
            yield link.resolved_parent
        case PurePath():
            if link.resolved_parent != link.path.parent:
                yield Policy.SWAPPED_PARENT


def _link_keep_reasons(probe: Probe, now: float) -> Iterator[KeepReason]:
    match probe:
        case Absent():
            yield Policy.GONE
        case Unknown():
            yield probe
        case Stat(kind=Kind.SYMLINK, mtime=mtime):
            if now - mtime <= ROOT_STALE_SECONDS:
                yield Policy.RECENT
        case Stat():
            yield Policy.NOT_A_LINK


def _foreign_owner(probe: Probe, uid: int) -> Iterator[KeepReason]:
    match probe:
        case Stat(uid=owner):
            if owner != uid:
                yield Policy.OTHER_OWNER
        case Absent():
            yield Policy.GONE
        case Unknown():
            yield probe


def parse_worktrees(listing: str) -> Fact[tuple[ListedWorktree, ...]]:
    """Reads `git worktree list --porcelain -z`: attributes end in NUL, records in NUL NUL."""
    records = [record for record in listing.split("\0\0") if record]
    worktrees = [_parse_worktree(record.split("\0")) for record in records]
    parsed = tuple(
        worktree for worktree in worktrees if isinstance(worktree, ListedWorktree)
    )
    if len(parsed) != len(records) or not parsed:
        return Unknown("the worktree listing")
    return parsed


def _parse_worktree(attributes: list[str]) -> ListedWorktree | None:
    match attributes[0].split(" ", 1):
        case ["worktree", path] if path.startswith("/"):
            locked = any(
                a == "locked" or a.startswith("locked ") for a in attributes[1:]
            )
            return ListedWorktree(PurePath(path), locked=locked)
        case _:
            return None


def parse_pids(listing: str, own_pid: int) -> Fact[frozenset[int]]:
    """Reads pgrep's output. Our own argv holds the pattern, so pgrep finds this process."""
    words = listing.split()
    if not all(word.isascii() and word.isdecimal() for word in words):
        return Unknown("the session processes")
    return frozenset(int(word) for word in words) - {own_pid}


def parse_count(output: str) -> Fact[int]:
    """Reads the single count git printed."""
    word = output.strip()
    return (
        int(word) if word.isascii() and word.isdecimal() else Unknown("a commit count")
    )


def read_worktree_decisions(
    repos_dir: Path, session_pattern: str
) -> Iterator[Decision]:
    sessions = read_sessions(session_pattern)
    for repository in _list_directory(repos_dir):
        if not (repository / ".git").is_dir():
            continue
        match read_worktrees(repository):
            case Unknown() as unknown:
                yield Keep(repository, unknown)
            case listed:
                for worktree in listed:
                    work = read_local_work(Path(worktree.path))
                    yield decide_worktree(
                        Worktree(worktree.path, repository, worktree.locked, work),
                        sessions,
                    )


def read_sessions(pattern: str) -> Fact[frozenset[PurePath]]:
    """The working directories of the processes matching pattern, as `sessions` in lib.sh."""
    match _run(
        ["pgrep", "-u", str(os.geteuid()), "-f", "--", pattern], accepted=(0, 1)
    ):
        case Unknown() as unknown:
            return unknown
        case listing:
            pass
    match parse_pids(listing, os.getpid()):
        case Unknown() as unknown:
            return unknown
        case pids:
            pass
    cwds: set[PurePath] = set()
    for pid in pids:
        match _read_cwd(pid):
            case Unknown() as unknown:
                return unknown
            case Absent():
                pass
            case PurePath() as cwd:
                cwds.add(cwd)
    return frozenset(cwds)


def _read_cwd(pid: int) -> Fact[PurePath] | Absent:
    try:
        return PurePath(Path(f"/proc/{pid}/cwd").readlink())
    except FileNotFoundError:
        return Absent()  # It ended between pgrep and here.
    except OSError:
        return Unknown(f"the working directory of process {pid}")


def read_worktrees(repository: Path) -> Fact[tuple[ListedWorktree, ...]]:
    match _run(["git", "-C", str(repository), "worktree", "list", "--porcelain", "-z"]):
        case Unknown() as unknown:
            return unknown
        case listing:
            return parse_worktrees(listing)


def read_local_work(directory: Path) -> LocalWork:
    """Remote Control keeps its worktrees under .claude/worktrees in the main
    checkout, untracked: they are worktrees of their own, not changes to it."""
    git = ["git", "-C", str(directory)]
    status = _run(
        [*git, "status", "--porcelain", "--", ".", ":(exclude).claude/worktrees"]
    )
    unpushed = _run([*git, "rev-list", "--count", "HEAD", "--not", "--remotes"])
    return LocalWork(
        uncommitted=status if isinstance(status, Unknown) else len(status.splitlines()),
        unpushed=unpushed if isinstance(unpushed, Unknown) else parse_count(unpushed),
    )


def read_cache_decisions(home: Path, qa_dir: Path) -> Iterator[Decision]:
    cache = home / ".cache"
    kept_for_builds = {cache / "nix", cache / "cabal", qa_dir}
    for path in (*_list_directory(cache), cache / "cabal/logs", home / ".npm/_cacache"):
        yield decide_cache(path, read_probe(path), kept_for_builds)


def read_qa_run_decisions(qa_dir: Path, now: float) -> Iterator[Decision]:
    """~/.cache/qa/<owner>/<repo>/runs/<run>: never auth/ or scripts/, which sit beside runs/."""
    for path in sorted(qa_dir.glob("*/*/runs/*")):
        yield decide_qa_run(QaRun(path, read_probe(path), read_newest_write(path)), now)


def read_newest_write(directory: Path) -> Fact[float]:
    try:
        newest = directory.lstat().st_mtime
        for parent, directories, files in directory.walk(on_error=_reraise):
            for name in (*directories, *files):
                newest = max(newest, (parent / name).lstat().st_mtime)
    except OSError:
        return Unknown(f"the newest write under {directory}")
    return newest


def _reraise(error: OSError) -> NoReturn:
    raise error


def read_gc_roots(gcroots_auto: Path) -> Iterator[GcRoot]:
    """Nix registers a build's result link as an indirect root in gcroots/auto, so a
    forgotten link pins its whole closure until it is deleted."""
    for entry in _list_directory(gcroots_auto):
        yield GcRoot(entry, read_result_link(entry))


def read_result_link(entry: Path) -> Fact[ResultLink]:
    try:
        target = entry.readlink()
    except OSError:
        return Unknown(f"the result link of {entry}")
    return ResultLink(target, read_resolved(target.parent), read_probe(target))


def read_resolved(directory: Path) -> Fact[PurePath]:
    try:
        return directory.resolve(strict=True)
    except OSError:
        return Unknown(f"where {directory} resolves")


def read_probe(path: Path) -> Probe:
    try:
        facts = path.lstat()
    except FileNotFoundError:
        return Absent()
    except OSError:
        return Unknown(f"the state of {path}")
    return Stat(_kind(facts.st_mode), facts.st_mtime, facts.st_uid)


def _kind(mode: int) -> Kind:
    if stat.S_ISLNK(mode):
        return Kind.SYMLINK
    return Kind.DIRECTORY if stat.S_ISDIR(mode) else Kind.FILE


def _list_directory(directory: Path) -> tuple[Path, ...]:
    """An unreadable listing lists nothing, so it removes nothing."""
    try:
        return tuple(sorted(directory.iterdir()))
    except OSError:
        return ()


def _run(argv: list[str], accepted: tuple[int, ...] = (0,)) -> Fact[str]:
    described = f"the output of {' '.join(argv)}"
    try:
        done = subprocess.run(
            argv,
            capture_output=True,
            check=False,
            encoding="utf-8",
            errors="surrogateescape",
        )
    except OSError:
        return Unknown(described)
    return done.stdout if done.returncode in accepted else Unknown(described)


def report(decisions: Iterable[Decision]) -> None:
    """Prints what to remove once every fact is in: a crash on the way removes nothing."""
    for decision in tuple(decisions):
        match decision:
            case Remove(path):
                _ = sys.stdout.buffer.write(os.fsencode(path) + b"\0")
            case Keep(path, Unknown(fact)):
                print(
                    f"factory-disk-plan: kept {path}: could not read {fact}",
                    file=sys.stderr,
                )
            case Keep():
                pass


def main(arguments: list[str]) -> int:
    match arguments:
        case ["worktrees", repos_dir, session_pattern]:
            report(read_worktree_decisions(Path(repos_dir), session_pattern))
        case ["local-work", directory]:
            print(*local_work_phrases(read_local_work(Path(directory))), sep="\n")
        case ["caches", home, qa_dir]:
            report(read_cache_decisions(Path(home), Path(qa_dir)))
        case ["qa-runs", qa_dir]:
            report(read_qa_run_decisions(Path(qa_dir), time.time()))
        case ["stale-roots", gcroots_auto, *directories]:
            now = time.time()
            stale = {PurePath(directory) for directory in directories}
            report(
                decide_stale_root(root, stale, now)
                for root in read_gc_roots(Path(gcroots_auto))
            )
        case ["own-stale-roots", gcroots_auto, *directories]:
            now = time.time()
            stale = {PurePath(directory) for directory in directories}
            uid = os.geteuid()
            report(
                decide_own_stale_root(root, stale, now, uid)
                for root in read_gc_roots(Path(gcroots_auto))
            )
        case _:
            print(
                "usage: factory-disk-plan worktrees|local-work|caches|qa-runs|stale-roots|own-stale-roots ...",
                file=sys.stderr,
            )
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
