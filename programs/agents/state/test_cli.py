"""The command line's usage: bad argv exits 2 with a fix line, help prints."""

from pathlib import Path

import pytest

from state.state_fixtures import OVERRIDE, log_of, ok, run, to_impl


@pytest.mark.parametrize(
    "argv",
    [
        ("bogus",),
        ("init",),
        ("record",),
        ("record", "quality", "Great"),
        ("brief", "pm"),
    ],
)
def test_bad_usage_exits_2_with_a_fix_line(repo: Path, argv: tuple[str, ...]) -> None:
    code, out, err = run(repo, *argv)

    assert (code, out) == (2, "")
    assert err.splitlines()[1].startswith("fix: ")


def test_help_prints_usage_and_exits_0(repo: Path) -> None:
    code, out, err = run(repo, "help")

    assert (code, err) == (0, "")
    assert out.splitlines()[0] == (
        "state - record the engineer flow as events; advise the next arrow"
    )
    assert "  state next " in out


def test_an_unknown_event_suggests_the_closest_one(repo: Path, tmp_path: Path) -> None:
    _ = ok(repo, "init", "--notes", str(tmp_path / "notes"))

    code, _, err = run(repo, "record", "plan", "p.md")

    assert code == 2
    assert err.splitlines()[1] == "fix: did you mean: state record planned <path>"


def test_an_off_arrow_event_is_refused_and_its_fix_command_works(
    repo: Path, tmp_path: Path
) -> None:
    notes = tmp_path / "notes"
    _ = ok(repo, "init", "--notes", str(notes))
    _ = ok(repo, "record", "planned", f"{notes}/plan.md")

    code, _, err = run(repo, "record", "asked", "1")
    fixed = OVERRIDE.search(err)
    assert fixed is not None
    moved = ok(repo, "override", fixed[1], "one more question")
    asked = ok(repo, "record", "asked", "1")

    assert code == 2
    assert moved == "recorded 3 overridden -> Ctx\n"
    assert asked == "recorded 4 asked -> Ctx\n"


def test_a_review_lead_handback_takes_its_head_from_the_flag(
    repo: Path, tmp_path: Path
) -> None:
    notes = tmp_path / "notes"
    to_impl(repo, notes)
    _ = ok(repo, "record", "implemented", "a1")

    handed = ok(repo, "handback", "review-lead", "--head", "9f8e7d6", stdin="READY\n")

    assert handed.startswith("recorded 8 reviewed -> ")
    assert log_of(notes)[-1]["event"] == {
        "type": "reviewed",
        "head": "9f8e7d6",
        "rows": [],
        "verdicts": [],
    }
