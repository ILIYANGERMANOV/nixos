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
from collections.abc import Callable, Collection, Iterable, Iterator
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


def main(arguments: list[str]) -> int:
    now = time.time()
    match arguments:
        case ["worktrees", repos_dir, session_pattern]:
            report(
                read_worktree_decisions(
                    Path(repos_dir), lambda: read_sessions(session_pattern)
                )
            )
        case ["local-work", directory]:
            print(*local_work_phrases(read_local_work(Path(directory))), sep="\n")
        case ["caches", home, qa_dir]:
            report(read_cache_decisions(Path(home), Path(qa_dir)))
        case ["qa-runs", qa_dir]:
            report(read_qa_run_decisions(Path(qa_dir), now))
        case ["stale-roots", gcroots_auto, *directories]:
            stale = {PurePath(directory) for directory in directories}
            report(
                read_gc_root_decisions(
                    Path(gcroots_auto),
                    lambda root: decide_stale_root(root, stale, now),
                )
            )
        case ["own-stale-roots", gcroots_auto, *directories]:
            stale = {PurePath(directory) for directory in directories}
            uid = os.geteuid()
            report(
                read_gc_root_decisions(
                    Path(gcroots_auto),
                    lambda root: decide_own_stale_root(root, stale, now, uid),
                )
            )
        case _:
            print(
                "usage: factory-disk-plan worktrees|local-work|caches|qa-runs|stale-roots|own-stale-roots ...",
                file=sys.stderr,
            )
            return 2
    return 0


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


type Sessions = Fact[frozenset[PurePath]]


def read_worktree_decisions(
    repos_dir: Path, read_live_sessions: Callable[[], Sessions]
) -> Iterator[Decision]:
    return _decide_entries(
        repos_dir,
        lambda repository: _read_repository_decisions(repository, read_live_sessions),
    )


def _read_repository_decisions(
    repository: Path, read_live_sessions: Callable[[], Sessions]
) -> Iterator[Decision]:
    """Sessions are read per worktree, last: one that starts mid-scan still counts."""
    if not (repository / ".git").is_dir():
        return
    match read_worktrees(repository):
        case Unknown() as unknown:
            yield Keep(repository, unknown)
        case listed:
            for worktree in listed:
                work = read_local_work(Path(worktree.path))
                yield decide_worktree(
                    Worktree(worktree.path, repository, worktree.locked, work),
                    read_live_sessions(),
                )


def _decide_entries(
    directory: Path, decide_entry: Callable[[Path], Iterable[Decision]]
) -> Iterator[Decision]:
    match _list_directory(directory):
        case Unknown() as unknown:
            yield Keep(directory, unknown)
        case entries:
            for entry in entries:
                yield from decide_entry(entry)


def read_sessions(pattern: str) -> Sessions:
    """The working directories of the processes matching pattern, as `sessions` in lib.sh."""
    listing = _run(
        ["pgrep", "-u", str(os.geteuid()), "-f", "--", pattern], accepted=(0, 1)
    )
    pids = _and_then(listing, lambda pgrep: parse_pids(pgrep, os.getpid()))
    return _and_then(pids, _read_cwds)


def _read_cwds(pids: frozenset[int]) -> Sessions:
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
    listing = _run(
        ["git", "-C", str(repository), "worktree", "list", "--porcelain", "-z"]
    )
    return _and_then(listing, parse_worktrees)


def read_local_work(directory: Path) -> LocalWork:
    """Of a checkout's root only. git walks up, so a worktree that lost its .git
    would otherwise answer for the clean checkout above it."""
    git = ["git", "-C", str(directory)]
    match _run([*git, "rev-parse", "--show-prefix"]):
        case "\n":
            return _read_checkout_work(git)
        case _:
            unknown = Unknown(f"whether {directory} is a checkout's root")
            return LocalWork(uncommitted=unknown, unpushed=unknown)


def _read_checkout_work(git: list[str]) -> LocalWork:
    """Remote Control keeps its worktrees under .claude/worktrees in the main
    checkout, untracked: they are worktrees of their own, not changes to it."""
    status = _run(
        [*git, "status", "--porcelain", "--", ".", ":(exclude).claude/worktrees"]
    )
    unpushed = _run([*git, "rev-list", "--count", "HEAD", "--not", "--remotes"])
    return LocalWork(
        uncommitted=_and_then(status, lambda lines: len(lines.splitlines())),
        unpushed=_and_then(unpushed, parse_count),
    )


def read_cache_decisions(home: Path, qa_dir: Path) -> Iterator[Decision]:
    cache = home / ".cache"
    kept_for_builds = {cache / "nix", cache / "cabal", qa_dir}

    def decide_path(path: Path) -> Iterator[Decision]:
        yield decide_cache(path, read_probe(path), kept_for_builds)

    yield from _decide_entries(cache, decide_path)
    for path in (cache / "cabal/logs", home / ".npm/_cacache"):
        yield from decide_path(path)


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


def read_gc_root_decisions(
    gcroots_auto: Path, decide_root: Callable[[GcRoot], Decision]
) -> Iterator[Decision]:
    """Nix registers a build's result link as an indirect root in gcroots/auto, so a
    forgotten link pins its whole closure until it is deleted."""

    def decide_entry(entry: Path) -> Iterator[Decision]:
        yield decide_root(GcRoot(entry, read_result_link(entry)))

    return _decide_entries(gcroots_auto, decide_entry)


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


def _list_directory(directory: Path) -> Fact[tuple[Path, ...]]:
    try:
        return tuple(sorted(directory.iterdir()))
    except FileNotFoundError:
        return ()  # Nothing there, so nothing to decide.
    except OSError:
        return Unknown(f"the listing of {directory}")


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


def _and_then[T, U](fact: Fact[T], step: Callable[[T], Fact[U]]) -> Fact[U]:
    match fact:
        case Unknown():
            return fact
        case known:
            return step(known)


def decide_worktree(worktree: Worktree, sessions: Sessions) -> Decision:
    """A secondary worktree whose deletion loses nothing goes.

    Only one inside its repository: a /qa run's or a /10x-engineer run's sits
    elsewhere, is clean and pushed while it waits, and its run removes it.
    """
    return decide(worktree.path, _worktree_keep_reasons(worktree, sessions))


def _worktree_keep_reasons(
    worktree: Worktree, sessions: Sessions
) -> Iterator[KeepReason]:
    if worktree.path == worktree.repository:
        yield Policy.MAIN_CHECKOUT
    if not worktree.path.is_relative_to(worktree.repository):
        yield Policy.OUTSIDE_REPOSITORY
    if worktree.locked:
        yield Policy.LOCKED
    yield from _keep_if(
        sessions,
        lambda cwds: any(cwd.is_relative_to(worktree.path) for cwd in cwds),
        Policy.LIVE_SESSION,
    )
    for count in (worktree.local_work.uncommitted, worktree.local_work.unpushed):
        yield from _keep_if(count, lambda known: known > 0, Policy.LOCAL_WORK)


def _keep_if[T](
    fact: Fact[T], holds: Callable[[T], bool], reason: Policy
) -> Iterator[KeepReason]:
    """The reason when a known fact holds; a fact not known keeps by itself."""
    match fact:
        case Unknown():
            yield fact
        case known:
            if holds(known):
                yield reason


def decide(path: PurePath, reasons: Iterable[KeepReason]) -> Decision:
    """Remove only when no reason to keep exists."""
    match next(iter(reasons), None):
        case None:
            return Remove(path)
        case reason:
            return Keep(path, reason)


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
    yield from _keep_if(
        run.newest_write,
        lambda written: now - written < QA_RUN_QUIET_SECONDS,
        Policy.RECENT,
    )


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
    yield from _keep_if(
        link.resolved_parent,
        lambda resolved: resolved != link.path.parent,
        Policy.SWAPPED_PARENT,
    )


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
        case Absent() | Unknown():
            pass  # _link_keep_reasons keeps these.


def parse_worktrees(listing: str) -> Fact[tuple[ListedWorktree, ...]]:
    """Reads `git worktree list --porcelain -z`: attributes end in NUL, records in NUL NUL."""
    records = [record for record in listing.split("\0\0") if record]
    parsed = tuple(_parse_worktree(record.split("\0")) for record in records)
    known = tuple(worktree for worktree in parsed if not isinstance(worktree, Unknown))
    if len(known) != len(parsed) or not known:
        return Unknown("the worktree listing")
    return known


def _parse_worktree(attributes: list[str]) -> Fact[ListedWorktree]:
    match attributes[0].split(" ", 1):
        case ["worktree", path] if path.startswith("/"):
            locked = any(
                a == "locked" or a.startswith("locked ") for a in attributes[1:]
            )
            return ListedWorktree(PurePath(path), locked=locked)
        case _:
            return Unknown("a worktree record")


def parse_pids(listing: str, own_pid: int) -> Fact[frozenset[int]]:
    """Reads pgrep's output. Our own argv holds the pattern, so pgrep finds this process."""
    words = listing.split()
    if not all(_is_natural(word) for word in words):
        return Unknown("the session processes")
    return frozenset(int(word) for word in words) - {own_pid}


def parse_count(output: str) -> Fact[int]:
    """Reads the single count git printed."""
    word = output.strip()
    return int(word) if _is_natural(word) else Unknown("a commit count")


def _is_natural(word: str) -> bool:
    return word.isascii() and word.isdecimal()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
