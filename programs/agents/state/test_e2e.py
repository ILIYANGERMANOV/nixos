"""The built `state` command, end to end: the wrapped binary the agents get on
PATH, run as a process on a temp git repo. No module of the program is imported,
so this proves the packaging - the wrapper, the package path, the entry point -
as well as the flow. `python-tests` puts the binary in $STATE."""

import os
import subprocess
from pathlib import Path

from state.state_fixtures import PR, commit

STATE = os.environ["STATE"]


def state(repo: Path, *argv: str, stdin: str | None = None) -> tuple[int, str, str]:
    done = subprocess.run(
        [STATE, *argv],
        cwd=repo,
        input=stdin,
        capture_output=True,
        text=True,
        check=False,
    )
    return done.returncode, done.stdout, done.stderr


def ok(repo: Path, *argv: str, stdin: str | None = None) -> str:
    code, out, err = state(repo, *argv, stdin=stdin)
    assert (code, err) == (0, ""), err
    return out


def drafted(repo: Path, notes: Path) -> None:
    """A delegated run up to Impl: its knobs set and draft PR 7 against main."""
    _ = ok(repo, "init", "--notes", str(notes), "--delegated")
    _ = ok(repo, "record", "size", "Normal")
    _ = ok(repo, "record", "quality", "Balanced")
    _ = ok(repo, "record", "drafted", PR, "main")


def test_a_run_goes_from_init_through_a_handback_to_the_review(
    repo: Path, tmp_path: Path
) -> None:
    notes = tmp_path / "notes"

    _ = ok(repo, "init", "--notes", str(notes), "--delegated")
    recorded = ok(repo, "record", "size", "Normal")
    _ = ok(repo, "record", "quality", "Balanced")
    to_impl = ok(repo, "record", "drafted", PR, "main")
    first = ok(repo, "next")
    head = commit(repo, {"b.txt": "two\n"}, "implement")
    handed = ok(repo, "handback", "implementer", stdin=f"READY {PR}\ndone\n")
    second = ok(repo, "next")
    shown = ok(repo, "show")

    assert (notes / "events.jsonl").is_file()
    assert recorded == "recorded 2 size -> DraftPlan\n"
    assert to_impl == "recorded 4 drafted -> Impl\n"
    assert first.splitlines()[0] == "SPAWN implementer"
    assert handed == "recorded 5 implemented -> Impl'\n"
    assert second.splitlines()[0] == "SPAWN review-lead"
    assert "Step: Impl'" in shown.splitlines()
    assert f"Head: {head}" in shown.splitlines()


def test_override_moves_off_the_advised_arrow_and_next_follows_it(
    repo: Path, tmp_path: Path
) -> None:
    drafted(repo, tmp_path / "notes")

    moved = ok(repo, "override", "PR", "skip the review")
    advice = ok(repo, "next")

    assert moved == "recorded 5 overridden -> PR\n"
    assert advice.splitlines()[0] == "WAIT ci"


def test_override_to_an_unknown_state_exits_2_listing_the_states(
    repo: Path, tmp_path: Path
) -> None:
    drafted(repo, tmp_path / "notes")

    code, out, err = state(repo, "override", "Bogus", "why")

    assert (code, out) == (2, "")
    assert err.splitlines()[0] == "state override: no state 'Bogus'"
    assert err.splitlines()[1].startswith("fix: states: Ctx ")


def test_a_hand_edited_bad_line_exits_2_naming_the_line(
    repo: Path, tmp_path: Path
) -> None:
    notes = tmp_path / "notes"
    drafted(repo, notes)
    log = notes / "events.jsonl"
    _ = log.write_text(log.read_text() + "{bad\n")

    code, out, err = state(repo, "show")

    assert (code, out) == (2, "")
    assert err.startswith(f"state: {log}:5: not JSON")
    assert f"fix: repair or delete line 5 of {log}" in err
