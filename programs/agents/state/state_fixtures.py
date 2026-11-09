"""What the `state` tests share: event builders, Hypothesis generators over
events, and the command line run on temp git repos, as test_ctx.py does."""

import io
import json
import re
import subprocess
import sys
from contextlib import redirect_stderr, redirect_stdout
from dataclasses import dataclass
from pathlib import Path
from typing import cast

from hypothesis import strategies as st

from state.core import Facts, GitFacts, NoFacts, advise, apply, fold, render_advice
from state.main import main
from state.model import (
    AREAS,
    BLOCKER_KINDS,
    MODES,
    OUTCOMES,
    PROPOSAL_MODES,
    ROLES,
    S0,
    STATES,
    Adjusted,
    Asked,
    Blocked,
    Ci,
    Confirmed,
    Defaulted,
    Drafted,
    Event,
    Failure,
    Fixed,
    Grew,
    Implemented,
    Json,
    Overridden,
    Picked,
    Planned,
    Proposed,
    Quality,
    Raised,
    Ready,
    Refactored,
    Researched,
    Resolved,
    Reviewed,
    Size,
    Started,
    State,
    Verdict,
)

NOTES = "/notes/run"
# The override an off-arrow refusal's fix line names; group 1 is the state.
OVERRIDE = re.compile(r'state override (\S+) "<why>"')
PR = "https://github.com/o/r/pull/7"
NO_FACTS = NoFacts()

# ---- Builders -------------------------------------------------------------------


def reach(*events: Event) -> State:
    match fold(events):
        case State() as state:
            return state
        case Failure() as failure:
            raise AssertionError(failure.message)


def drafted(
    quality: str = "Balanced", size: str = "Normal", *, delegated: bool = False
) -> list[Event]:
    """A run up to Impl: the plan confirmed and the draft PR 7 against main."""
    started = Started(NOTES, delegated=delegated)
    knobs = [Size(size), Quality(quality)]  # pyright: ignore[reportArgumentType]
    if delegated:
        return [started, *knobs, Drafted(PR, "main", "feature")]
    return [
        started,
        knobs[0],
        Planned(f"{NOTES}/plan.md"),
        knobs[1],
        *(Proposed(m) for m in PROPOSAL_MODES),
        Confirmed(),
        Drafted(PR, "main", "feature"),
    ]


def review(
    head: str, rows: tuple[str, ...] = (), verdicts: tuple[Verdict, ...] = ()
) -> tuple[Reviewed, Picked]:
    """A review back on `head`, then the lead's picks from it."""
    return Reviewed(head), Picked(rows, verdicts)


def reviewed(quality: str = "Balanced", size: str = "Normal") -> list[Event]:
    """Implemented, refactored, then a first review that chose rows R1 and R2."""
    return [
        *drafted(quality, size),
        Implemented("h1"),
        Refactored("h2"),
        *review("h3", ("R1", "R2")),
    ]


def final_fixed(quality: str = "Balanced", *, delegated: bool = False) -> list[Event]:
    """A run in DraftPR: a first review with no rows, then the final fixer."""
    return [
        *drafted(quality, delegated=delegated),
        Implemented("h1"),
        Refactored("h2"),
        *review("h3"),
        Fixed("h4", ()),
    ]


def advice(*events: Event, facts: Facts = NO_FACTS) -> str:
    return render_advice(advise(reach(*events), facts))


def first_line(text: str) -> str:
    return text.splitlines()[0]


# ---- Generators -----------------------------------------------------------------

# Small alphabets, so heads, rows and questions repeat and the guards see it.
heads = st.sampled_from(["a1", "b2", "c3"])
labels = st.sampled_from(["R1", "R2", "R3"])
questions = st.sampled_from(["q1", "q2"])
pr_urls = st.integers(1, 9).map(lambda n: f"https://github.com/o/r/pull/{n}")

events: st.SearchStrategy[Event] = st.one_of(
    st.builds(Started, st.just(NOTES), st.booleans()),
    st.builds(Quality, st.sampled_from(MODES)),
    st.builds(Size, st.sampled_from(("Trivial", "Normal"))),
    st.builds(Grew, st.just("bigger")),
    st.builds(Defaulted, st.sampled_from(("quality", "size"))),
    st.builds(Researched, st.integers(1, 3)),
    st.builds(Asked, st.integers(1, 3)),
    st.builds(Planned, st.just(f"{NOTES}/plan.md")),
    st.builds(Proposed, st.sampled_from(PROPOSAL_MODES)),
    st.builds(Confirmed),
    st.builds(Adjusted),
    st.builds(Drafted, pr_urls, st.just("main"), st.just("feature")),
    st.builds(Implemented, heads),
    st.builds(Refactored, heads),
    st.builds(Reviewed, heads),
    st.builds(
        Picked,
        st.lists(labels, max_size=2).map(tuple),
        st.lists(
            st.builds(
                Verdict, st.sampled_from(["AC1", "AC2"]), st.sampled_from(OUTCOMES)
            ),
            max_size=2,
        ).map(tuple),
    ),
    st.builds(Fixed, heads, st.lists(st.sampled_from(AREAS), max_size=2).map(tuple)),
    st.builds(
        Ci, heads, st.lists(st.sampled_from(["lint", "test"]), max_size=2).map(tuple)
    ),
    st.builds(Raised, questions, st.sampled_from(ROLES)),
    st.builds(
        Blocked, questions, st.sampled_from(BLOCKER_KINDS), st.sampled_from(ROLES)
    ),
    st.builds(Resolved, questions, st.just("yes")),
    st.builds(Overridden, st.sampled_from(STATES), st.just("why")),
    st.builds(Ready, pr_urls),
)
event_lists = st.lists(events, max_size=40)
facts: st.SearchStrategy[Facts] = st.one_of(
    st.just(NoFacts()),
    st.builds(
        GitFacts, st.integers(0, 300), st.sampled_from(["none", "changed", "new"])
    ),
)


def walk(candidates: list[Event]) -> list[tuple[State, Event, State]]:
    """Each accepted arrow of a run that offers `candidates` in order and keeps
    only the events the flow accepts, as a lead that reads the error would."""
    steps: list[tuple[State, Event, State]] = []
    state = S0
    for event in candidates:
        match apply(state, event):
            case State() as after:
                steps.append((state, event, after))
                state = after
            case Failure():
                pass
    return steps


def accepted(candidates: list[Event]) -> list[Event]:
    return [event for _, event, _ in walk(candidates)]


# ---- The command line on temp git repos ---------------------------------------------

IDENTITY = ("-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false")


def git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *IDENTITY, *args], cwd=repo, check=True, capture_output=True, text=True
    ).stdout


def commit(repo: Path, files: dict[str, str], message: str) -> str:
    for name, text in files.items():
        path = repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        _ = path.write_text(text)
    _ = git(repo, "add", "--all")
    _ = git(repo, "commit", "--quiet", f"--message={message}")
    return git(repo, "rev-parse", "HEAD").strip()


def make_repo(root: Path) -> Path:
    """main has one commit, which origin/main points at; `feature` is checked out."""
    path = root / "repo"
    path.mkdir()
    _ = git(path, "init", "--quiet", "--initial-branch=main")
    _ = commit(path, {"a.txt": "one\n"}, "base")
    _ = git(path, "update-ref", "refs/remotes/origin/main", "HEAD")
    _ = git(path, "switch", "--quiet", "--create", "feature")
    return path


def run(cwd: Path, *argv: str, stdin: str | None = None) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        code = main(list(argv), cwd, stdin)
    return code, out.getvalue(), err.getvalue()


def ok(cwd: Path, *argv: str, stdin: str | None = None) -> str:
    code, out, err = run(cwd, *argv, stdin=stdin)
    assert (code, err) == (0, ""), err
    return out


def log_of(notes: Path) -> list[dict[str, object]]:
    return [
        json.loads(line) for line in (notes / "events.jsonl").read_text().splitlines()
    ]


def to_impl(repo: Path, notes: Path) -> None:
    """init, then the shortest recorded path to Impl at Balanced, PR 7 from
    `feature` to main."""
    to_draft(repo, notes)
    _ = ok(repo, "record", "drafted", PR, "main", "feature")


def to_draft(repo: Path, notes: Path) -> None:
    """init, then a Balanced run with its plan confirmed and no draft PR yet."""
    for argv in (
        ("init", "--notes", str(notes)),
        ("record", "size", "Normal"),
        ("record", "planned", f"{notes}/plan.md"),
        ("record", "quality", "Balanced"),
        ("record", "confirmed"),
    ):
        _ = ok(repo, *argv)


def older_log(notes: Path) -> None:
    """Rewrites the log as a `state` from before runs were bound to a branch
    wrote it: its drafted line has no branch."""
    log = notes / "events.jsonl"
    _ = log.write_text(log.read_text().replace(',"branch":"feature"', ""))


# ---- GitHub, faked -------------------------------------------------------------

# A `gh` on PATH that answers `gh pr view [<url>] --json <fields>` from a JSON
# file of PRs, as gh does: by URL, or the current branch's PR, an open one
# first. It logs each call's arguments, a line each, beside the file.
FAKE_GH = f"""#!{sys.executable}
import json, os, subprocess, sys
from pathlib import Path

world = Path(os.environ["FAKE_GITHUB"])
with world.with_suffix(".calls").open("a") as calls:
    calls.write(" ".join(sys.argv[1:]) + "\\n")
found = json.loads(world.read_text())
if found["down"]:
    sys.exit(found["down"])
match sys.argv[1:]:
    case ["pr", "view", "--json", fields]:
        branch = subprocess.run(
            ["git", "symbolic-ref", "--short", "HEAD"], capture_output=True, text=True
        ).stdout.strip()
        prs = [p for p in found["prs"] if p["headRefName"] == branch]
        prs.sort(key=lambda p: p["state"] != "OPEN")
        missing = f'no pull requests found for branch "{{branch}}"'
    case ["pr", "view", url, "--json", fields]:
        prs = [p for p in found["prs"] if p["url"] == url]
        missing = (
            "GraphQL: Could not resolve to a PullRequest with the number of "
            f"{{url.rsplit('/', 1)[-1]}}. (repository.pullRequest)"
        )
    case _:
        sys.exit(f"fake gh: {{sys.argv[1:]}}")
if not prs:
    sys.exit(missing)
print(json.dumps({{k: prs[0][k] for k in fields.split(",")}}))
"""


@dataclass(frozen=True)
class GitHub:
    """The fake `gh`'s world: PRs by URL, and whether it is down."""

    world: Path

    def install(self, bin_dir: Path) -> None:
        script = bin_dir / "gh"
        _ = script.write_text(FAKE_GH)
        script.chmod(0o755)
        self.clear()

    def clear(self) -> None:
        _ = self.world.write_text(json.dumps({"down": None, "prs": []}))

    def open(
        self,
        url: str = PR,
        *,
        base: str = "main",
        branch: str = "feature",
        draft: bool = True,
        state: str = "OPEN",
    ) -> None:
        """The PR at `url` as given, replacing what was there."""
        pr: dict[str, Json] = {
            "url": url,
            "baseRefName": base,
            "headRefName": branch,
            "isDraft": draft,
            "state": state,
        }
        found = self.read()
        prs = [
            p for p in cast("list[dict[str, Json]]", found["prs"]) if p["url"] != url
        ]
        _ = self.world.write_text(json.dumps(found | {"prs": [*prs, pr]}))

    def down(self, why: str) -> None:
        """Every call fails, exit 1, printing `why`, as gh does offline."""
        _ = self.world.write_text(json.dumps(self.read() | {"down": why}))

    def read(self) -> dict[str, Json]:
        return cast("dict[str, Json]", json.loads(self.world.read_text()))

    def calls(self) -> list[str]:
        calls = self.world.with_suffix(".calls")
        return calls.read_text().splitlines() if calls.exists() else []
