"""`ctx`: write a branch diff to a cached folder and print its path and manifest.

Agents read a review diff from the folder instead of each deriving their own.
A folder is content-addressed: its key hashes the from-commit, the head commit,
the head tree and this file's own bytes, so the same inputs give the same
folder and any change to this script is a new key. A folder is built in a temp
folder and renamed into place, so a reader never sees half of one. Stdlib only.
"""

import errno
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

type Kind = Literal["diff", "delta"]
type Files = dict[str, str]

# Shared by every account on the box, so ctx refuses one another account owns.
STORE = Path("/tmp/ctx")  # noqa: S108

HELP = """\
ctx - write a branch diff to a cached folder; print its path and manifest

  ctx diff  <base> [<head>]   merge-base(base, head) .. head  (review a branch)
  ctx delta <prev> [<head>]   prev .. head, no merge-base     (what changed since a review)
  <head> omitted: the work tree, uncommitted and untracked files included
              (.gitignore respected; your index is not touched)

Examples
  ctx diff origin/main            whole branch incl. uncommitted work
  ctx delta 1a2b3c4 HEAD          commits since the reviewed sha 1a2b3c4

Output (stdout)
  line 1   folder path, alone: d=$(ctx diff origin/main | head -1)
  then     refs, file count, +/- lines, cached: yes|no, one line per file
Folder   index status stat log diff (delta adds: ancestor)
  index    <path> <first> <last>: the file's line range in diff
Read     index first, then: sed -n '<first>,<last>p' "$d/diff"
Exit     0 ok (cached reruns too)  2 bad usage or ref  1 git or disk failure
Errors go to stderr with a fix: line. Same inputs give the same folder.
"""

# What each file in a folder holds, in the order the manifest lists them.
MEANINGS = {
    "index": "<path> <first> <last>: each file's line range in diff",
    "status": "git diff --name-status",
    "stat": "git diff --stat",
    "log": "commits {range}, one per line",
    "ancestor": "yes|no: prev is an ancestor of head",
    "diff": "unified diff",
}

STAT_SUMMARY = re.compile(
    r" (\d+) files? changed(?:, (\d+) insertions?\(\+\))?(?:, (\d+) deletions?\(-\))?"
)


# ---- Requests -------------------------------------------------------------


@dataclass(frozen=True)
class Help:
    """`ctx`, `ctx help` or `-h`/`--help` anywhere."""


@dataclass(frozen=True)
class Request:
    """A diff or delta from `ref` to `head`; no head means the work tree."""

    kind: Kind
    ref: str
    head: str | None


@dataclass(frozen=True)
class Failure:
    """Something the caller can fix: a `what - why` line, a fix, an exit code."""

    message: str
    fix: str
    code: int


def parse_args(argv: list[str]) -> Help | Request | Failure:
    """Read the command line; never touches git."""
    match argv:
        case [] | ["help"]:
            return Help()
        case _ if "-h" in argv or "--help" in argv:
            return Help()
        case ["diff" | "delta" as kind, ref]:
            return Request(kind, ref, None)
        case ["diff" | "delta" as kind, ref, head]:
            return Request(kind, ref, head)
        case ["diff" | "delta" as kind, *_]:
            return Failure(
                f"ctx {kind}: takes <ref> [<head>], got {len(argv) - 1} arguments",
                f"ctx {kind} origin/main",
                2,
            )
        case _:
            return Failure(
                f"ctx: unknown command '{argv[0]}'. Commands: diff, delta. See ctx --help",
                "ctx --help",
                2,
            )


# ---- Resolving refs ---------------------------------------------------------


@dataclass(frozen=True)
class Committed:
    """A head given as a ref: its commit and that commit's tree."""

    ref: str
    commit: str
    tree: str


@dataclass(frozen=True)
class WorkTree:
    """The work tree, snapshot to a tree object on top of the HEAD commit."""

    commit: str
    tree: str


type Head = Committed | WorkTree


@dataclass(frozen=True)
class DiffRange:
    """merge-base(base, head) .. head."""

    base: str
    merge_base: str
    head: Head


@dataclass(frozen=True)
class DeltaRange:
    """prev .. head, and whether prev is an ancestor of head."""

    prev: str
    prev_commit: str
    head: Head
    ancestor: bool


type Range = DiffRange | DeltaRange


def resolve(repo: Path, request: Request) -> Range | Failure:
    """Turn the refs into commits and a head tree; snapshots the work tree."""
    head = resolve_head(repo, request)
    match head:
        case Failure():
            return head
        case Committed() | WorkTree():
            pass
    match request.kind:
        case "diff":
            return resolve_diff(repo, request.ref, head)
        case "delta":
            return resolve_delta(repo, request.ref, head)


def resolve_head(repo: Path, request: Request) -> Head | Failure:
    match request.head:
        case None:
            commit = rev_parse(repo, "HEAD")
            match commit:
                case None:
                    return Failure(
                        f"ctx {request.kind}: HEAD is not a commit - the repo has no commits yet",
                        "git commit, then rerun",
                        2,
                    )
                case str():
                    return WorkTree(commit, snapshot(repo))
        case str(ref):
            commit = rev_parse(repo, ref)
            match commit:
                case None:
                    return Failure(
                        f"ctx {request.kind}: unknown ref '{ref}' - not a commit in this repo",
                        f"git fetch origin && ctx {request.kind} {request.ref} {ref}",
                        2,
                    )
                case str():
                    return Committed(
                        ref,
                        commit,
                        git(repo, "rev-parse", f"{commit}^{{tree}}").strip(),
                    )


def resolve_diff(repo: Path, base: str, head: Head) -> DiffRange | Failure:
    base_commit = rev_parse(repo, base)
    if base_commit is None:
        return Failure(
            f"ctx diff: unknown ref '{base}' - not a commit in this repo",
            "git fetch origin main && ctx diff origin/main",
            2,
        )
    found = run_git(repo, "merge-base", base_commit, head.commit)
    match found.returncode:
        case 0:
            return DiffRange(base, found.stdout.strip(), head)
        case _:
            return Failure(
                f"ctx diff: no merge-base between '{base}' and the head - unrelated histories",
                f"ctx delta {base}",
                2,
            )


def resolve_delta(repo: Path, prev: str, head: Head) -> DeltaRange | Failure:
    prev_commit = rev_parse(repo, prev)
    if prev_commit is None:
        return Failure(
            f"ctx delta: {prev} is not a commit here - pruned or never fetched",
            "git fetch origin <branch>, or review the whole branch: ctx diff origin/main",
            2,
        )
    ancestor = run_git(repo, "merge-base", "--is-ancestor", prev_commit, head.commit)
    return DeltaRange(prev, prev_commit, head, ancestor.returncode == 0)


def snapshot(repo: Path) -> str:
    """The work tree as a tree object, through a temp index.

    The temp index starts as a copy of the real one, so git's stat cache keeps
    `add -A` fast; the real index is never written. The new blobs land in the
    object store, the only write outside the ctx store.
    """
    real_index = repo / git(repo, "rev-parse", "--git-path", "index").strip()
    with tempfile.TemporaryDirectory(prefix="ctx-index-") as tmp:
        index = Path(tmp) / "index"
        if real_index.exists():
            _ = shutil.copyfile(real_index, index)
        env = {**os.environ, "GIT_INDEX_FILE": str(index)}
        _ = git(repo, "add", "--all", env=env)
        return git(repo, "write-tree", env=env).strip()


# ---- Building a folder ------------------------------------------------------


def from_commit(target: Range) -> str:
    match target:
        case DiffRange(merge_base=sha) | DeltaRange(prev_commit=sha):
            return sha


def kind_of(target: Range) -> Kind:
    match target:
        case DiffRange():
            return "diff"
        case DeltaRange():
            return "delta"


def key(target: Range, version: str) -> str:
    """Every input the folder depends on; the refs' names are not among them."""
    parts = [
        kind_of(target),
        from_commit(target),
        target.head.commit,
        target.head.tree,
        version,
    ]
    return hashlib.sha256("\0".join(parts).encode()).hexdigest()[:16]


def build(repo: Path, target: Range) -> Files:
    """The folder's files. Every diff is from a commit to a tree, so committed
    heads and work tree snapshots take the same path."""
    start, tree = from_commit(target), target.head.tree
    patch = git(repo, "diff", *DIFF_FLAGS, start, tree)
    names = git(repo, "diff", *DIFF_FLAGS, "--name-only", "-z", start, tree)
    files: Files = {
        "index": index_of(patch, [n for n in names.split("\0") if n]),
        "status": git(repo, "diff", *DIFF_FLAGS, "--name-status", start, tree),
        "stat": git(
            repo,
            "diff",
            *DIFF_FLAGS,
            "--stat=200",
            "--stat-graph-width=40",
            start,
            tree,
        ),
        "log": git(
            repo, "log", "--oneline", "--no-decorate", f"{start}..{target.head.commit}"
        ),
        "diff": patch,
    }
    match target:
        case DeltaRange(ancestor=ancestor):
            return files | {"ancestor": "yes\n" if ancestor else "no\n"}
        case DiffRange():
            return files


# The user's git config must not change what a folder holds.
DIFF_FLAGS = (
    "--no-color",
    "--no-ext-diff",
    "--no-textconv",
    "--src-prefix=a/",
    "--dst-prefix=b/",
)


def index_of(patch: str, names: list[str]) -> str:
    """`<path> <first> <last>` per file: its 1-based line range in `patch`.

    `names` come from `--name-only -z`, which lists the files in the order the
    patch does, so paths need no parsing out of the headers.
    """
    lines = patch.splitlines()
    starts = [i + 1 for i, line in enumerate(lines) if line.startswith("diff --git ")]
    if len(starts) != len(names):
        raise RuntimeError(
            f"{len(names)} names for {len(starts)} file sections in the diff"
        )
    ends = [start - 1 for start in starts[1:]] + ([len(lines)] if starts else [])
    return "".join(
        f"{name} {first} {last}\n"
        for name, first, last in zip(names, starts, ends, strict=True)
    )


def materialize(store: Path, name: str, make: Callable[[], Files]) -> tuple[Path, bool]:
    """The folder `store/name` and whether it was there already.

    Builds into a temp folder and renames it into place. When another build
    won the rename, its folder stays and this one's temp folder goes.
    """
    final = store / name
    if final.is_dir():
        return final, True
    store.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix=".tmp-", dir=store))
    for file, text in make().items():
        _ = (tmp / file).write_text(text)
    try:
        _ = tmp.rename(final)
    except OSError as error:
        match error.errno:
            case errno.EEXIST | errno.ENOTEMPTY:
                shutil.rmtree(tmp)
            case _:
                raise
    return final, False


# ---- The manifest -----------------------------------------------------------


def manifest(folder: Path, target: Range, *, cached: bool) -> str:
    """What stdout says: the folder alone on line 1, then facts about it."""
    stat = (folder / "stat").read_text()
    count, added, deleted = stat_totals(stat)
    order = ["index", "status", "stat", "log", "ancestor", "diff"]
    rows = [
        f"  {name:<8}{line_count(folder / name):>4}  {meaning(name, target)}"
        for name in order
        if (folder / name).exists()
    ]
    return "\n".join(
        [
            str(folder),
            describe(target),
            f"{count} files, +{added} -{deleted}, cached: {'yes' if cached else 'no'}",
            *rows,
            "read: index, then sed -n '<first>,<last>p' diff per file",
            "",
        ]
    )


def describe(target: Range) -> str:
    match target:
        case DiffRange(base=base, merge_base=merge_base, head=head):
            return f"diff {base} (merge-base {merge_base[:7]}) .. {head_label(head)}"
        case DeltaRange(prev=prev, head=head, ancestor=ancestor):
            fact = (
                "yes"
                if ancestor
                else "no (history rewritten: delta includes rebase changes)"
            )
            return f"delta {prev} .. {head_label(head)}, ancestor: {fact}"


def head_label(head: Head) -> str:
    match head:
        case Committed(ref=ref, commit=commit):
            return f"{ref} {commit[:7]}"
        case WorkTree(commit=commit, tree=tree):
            return f"work tree (HEAD {commit[:7]}, tree {tree[:7]})"


def meaning(name: str, target: Range) -> str:
    match target:
        case DiffRange():
            span = "merge-base..head"
        case DeltaRange():
            span = "prev..head"
    return MEANINGS[name].format(range=span)


def stat_totals(stat: str) -> tuple[int, int, int]:
    """Files, insertions and deletions from `git diff --stat`'s summary line."""
    found = STAT_SUMMARY.search(stat)
    match found:
        case None:
            return 0, 0, 0
        case re.Match():
            return tuple(int(group or 0) for group in found.groups())  # pyright: ignore[reportReturnType]


def line_count(path: Path) -> int:
    return len(path.read_text().splitlines())


# ---- The shell --------------------------------------------------------------


def repo_slug(origin_url: str | None, toplevel: Path) -> str:
    """`<owner>-<repo>` from the origin URL, else the top-level folder's name."""
    match origin_url:
        case None:
            return toplevel.name
        case str(url):
            parts = [
                p
                for p in re.split(
                    r"[/:]", url.strip().removesuffix("/").removesuffix(".git")
                )
                if p
            ]
            return "-".join(parts[-2:]) if len(parts) >= 2 else toplevel.name  # noqa: PLR2004


def ctx(cwd: Path, request: Request, store: Path, version: str) -> str | Failure:
    """Resolve, build on a miss, and return the manifest, or the failure."""
    top = run_git(cwd, "rev-parse", "--show-toplevel")
    if top.returncode != 0:
        return Failure(
            f"ctx: not inside a git work tree (cwd {cwd})",
            "cd <repo> or git -C <repo> ... ; ctx runs in the current repo",
            2,
        )
    repo = Path(top.stdout.strip())
    target = resolve(repo, request)
    match target:
        case Failure():
            return target
        case DiffRange() | DeltaRange():
            store.mkdir(parents=True, exist_ok=True)
            if store.stat().st_uid != os.getuid():
                return Failure(
                    f"ctx: {store} belongs to another account - its folders cannot be trusted",
                    f"sudo rm -rf {store}, then rerun",
                    1,
                )
            origin = run_git(repo, "config", "--get", "remote.origin.url")
            slug = repo_slug(origin.stdout if origin.returncode == 0 else None, repo)
            folder, cached = materialize(
                store / slug / request.kind,
                key(target, version),
                lambda: build(repo, target),
            )
            return manifest(folder, target, cached=cached)


def main(argv: list[str], cwd: Path, store: Path = STORE) -> int:
    parsed = parse_args(argv)
    match parsed:
        case Help():
            _ = sys.stdout.write(HELP)
            return 0
        case Failure():
            return report(parsed)
        case Request():
            version = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
            try:
                result = ctx(cwd, parsed, store, version)
            except GitError as error:
                return report(
                    Failure(
                        f"ctx {parsed.kind}: git failed - {error}",
                        "run that git command in the repo to see why",
                        1,
                    )
                )
            except OSError as error:
                return report(
                    Failure(
                        f"ctx {parsed.kind}: cannot build the folder - {error}",
                        f"df -h {store.parent}; check write access to {store}",
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


def rev_parse(repo: Path, ref: str) -> str | None:
    found = run_git(
        repo,
        "rev-parse",
        "--verify",
        "--quiet",
        "--end-of-options",
        f"{ref}^{{commit}}",
    )
    return found.stdout.strip() if found.returncode == 0 else None


class GitError(Exception):
    """A git command that should not fail did: an outage, not a bad ref."""


def git(repo: Path, *args: str, env: dict[str, str] | None = None) -> str:
    done = subprocess.run(
        ["git", *args], cwd=repo, env=env, check=False, capture_output=True, text=True
    )
    if done.returncode != 0:
        raise GitError(f"git {' '.join(args)}: {done.stderr.strip()}")
    return done.stdout


def run_git(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args], cwd=repo, check=False, capture_output=True, text=True
    )


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], Path.cwd()))
