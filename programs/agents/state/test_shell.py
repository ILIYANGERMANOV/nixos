"""The effects on temp git repos: the log on disk, the notes pointer, the git
facts and every command run end to end."""

import tempfile
from pathlib import Path

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st
from state_fixtures import commit, first_line, log_of, make_repo, ok, run, to_impl

COMMANDS = st.sampled_from(
    [
        ("init",),
        ("record", "researched"),
        ("record", "asked", "3"),
        ("record", "quality", "POC"),
        ("record", "quality", "Max"),
        ("record", "size", "Normal"),
        ("record", "size", "Trivial"),
        ("record", "grew", "bigger"),
        ("record", "planned", "plan.md"),
        ("record", "confirmed"),
        ("record", "drafted", "7", "main"),
        ("record", "implemented"),
        ("record", "bogus"),
        ("override", "PR", "jump"),
    ]
)


@settings(deadline=None, max_examples=25)
@given(st.lists(COMMANDS, min_size=1, max_size=8))
def test_shell_the_log_is_append_only_with_a_dense_seq_from_1(
    commands: list[tuple[str, ...]],
) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        repo = make_repo(Path(tmp))
        notes = Path(tmp) / "notes"
        _ = ok(repo, "init", "--notes", str(notes))
        log = notes / "events.jsonl"
        for command in commands:
            before = log.read_text()
            argv = ("init", "--notes", str(notes)) if command == ("init",) else command

            code, out, _ = run(repo, *argv)

            after = log.read_text()
            assert after.startswith(before)
            appended = after[len(before) :].splitlines()
            reported = [
                line for line in out.splitlines() if line.startswith("recorded ")
            ]
            assert len(appended) == (len(reported) if code == 0 else 0)
        seqs = [line["seq"] for line in log_of(notes)]
        assert seqs == list(range(1, len(seqs) + 1))


def test_init_creates_the_notes_dir_and_a_started_line(
    repo: Path, tmp_path: Path
) -> None:
    notes = tmp_path / "engineer-owner-repo-slug"

    out = ok(repo, "init", "--notes", str(notes))

    assert out == f"{notes}/events.jsonl\nstarted: yes\n"
    [line] = log_of(notes)
    assert line["seq"] == 1
    assert line["event"] == {"type": "started", "notes": str(notes), "delegated": False}


def test_init_twice_appends_nothing_and_exits_0(repo: Path, tmp_path: Path) -> None:
    notes = tmp_path / "notes"
    _ = ok(repo, "init", "--notes", str(notes))
    before = (notes / "events.jsonl").read_text()

    out = ok(repo, "init", "--notes", str(notes))

    assert out == f"{notes}/events.jsonl\nstarted: already\n"
    assert (notes / "events.jsonl").read_text() == before


def test_a_line_carries_seq_head_and_the_runners_session(
    repo: Path, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("STATE_SESSION", "s-42")
    head = commit(repo, {"b.txt": "b\n"}, "work")

    _ = ok(repo, "init", "--notes", str(tmp_path / "notes"))

    [line] = log_of(tmp_path / "notes")
    assert (line["head"], line["session"]) == (head, "s-42")


def test_record_prints_each_appended_line_and_the_state_it_reaches(
    repo: Path, tmp_path: Path
) -> None:
    _ = ok(repo, "init", "--notes", str(tmp_path / "notes"))

    out = ok(repo, "record", "size", "Normal")

    assert out == "recorded 2 size -> Ctx\n"


def test_drafting_with_quality_unset_records_it_defaulted(
    repo: Path, tmp_path: Path
) -> None:
    for argv in (
        ("init", "--notes", str(tmp_path / "notes")),
        ("record", "size", "Normal"),
        ("record", "planned", "p.md"),
        ("record", "confirmed"),
    ):
        _ = ok(repo, *argv)

    out = ok(repo, "record", "drafted", "7", "main")

    assert out == "recorded 5 defaulted -> Impl\nrecorded 6 drafted -> Impl\n"
    assert "Quality: Balanced (defaulted)" in ok(repo, "show")


def test_an_event_off_the_table_exits_2_and_appends_nothing(
    repo: Path, tmp_path: Path
) -> None:
    _ = ok(repo, "init", "--notes", str(tmp_path / "notes"))

    code, _, err = run(repo, "record", "ready", "7")

    assert code == 2
    assert err.startswith("state record: 'ready' is not an arrow out of Ctx\nfix: ")
    assert len(log_of(tmp_path / "notes")) == 1


def test_override_moves_the_state_and_next_advises_its_arrow(
    repo: Path, tmp_path: Path
) -> None:
    _ = ok(repo, "init", "--notes", str(tmp_path / "notes"))

    out = ok(repo, "override", "Impl", "the plan is in the issue")

    assert out == "recorded 2 overridden -> Impl\n"
    assert first_line(ok(repo, "next")) == "SPAWN implementer"


def test_handback_fixer_records_blocked_then_fixed(repo: Path, tmp_path: Path) -> None:
    notes = tmp_path / "notes"
    to_impl(repo, notes)
    _ = ok(repo, "record", "implemented")
    _ = ok(repo, "record", "refactored")
    _ = ok(
        repo, "handback", "review-lead", "--row", "R1", stdin="x\nReviewed head: abc\n"
    )

    blocked = ok(
        repo, "handback", "fixer", "--kind", "fact", stdin="NEEDS_DECISION q?\n"
    )
    fixed = ok(repo, "handback", "fixer", stdin="READY\n")

    assert (blocked, fixed) == (
        "recorded 10 blocked -> Impl''\n",
        "recorded 11 fixed -> Impl''\n",
    )
    assert log_of(notes)[8]["event"] == {
        "type": "reviewed", "head": "abc", "rows": ["R1"], "verdicts": [],
    }  # fmt: skip


def test_next_skips_the_refactor_on_a_small_balanced_diff(
    repo: Path, tmp_path: Path
) -> None:
    to_impl(repo, tmp_path / "notes")
    _ = commit(repo, {"b.txt": "x\n" * 60, "flake.lock": "y\n" * 500}, "work")
    _ = ok(repo, "record", "implemented")

    out = ok(repo, "next")

    assert first_line(out) == "SPAWN review-lead"
    assert "  refactor skipped: 60 changed lines, Balanced" in out.splitlines()


def test_next_refactors_a_large_balanced_diff_and_dry_runs_a_new_skill(
    repo: Path, tmp_path: Path
) -> None:
    to_impl(repo, tmp_path / "notes")
    _ = commit(repo, {"b.txt": "x\n" * 101}, "work")
    _ = ok(repo, "record", "implemented")
    refactor = first_line(ok(repo, "next"))
    _ = commit(repo, {"skills/new/SKILL.md": "# New\n"}, "skill")
    _ = ok(repo, "record", "refactored")

    review = ok(repo, "next")

    assert refactor == "SPAWN refactorer"
    assert "also: SPAWN reviewer" in review


def test_show_prints_the_progress_view(repo: Path, tmp_path: Path) -> None:
    notes = tmp_path / "notes"
    to_impl(repo, notes)
    _ = ok(repo, "record", "implemented", "h1")
    _ = ok(repo, "record", "refactored", "h2")
    _ = ok(repo, "record", "reviewed", "h3", "--row", "R1")
    _ = ok(repo, "record", "blocked", "fact", "fixer", "which log?")

    out = ok(repo, "show")

    assert out.splitlines() == [
        "Step: Impl''",
        "Head: h3",
        "Quality: Balanced",
        "Size: Normal",
        "Re-review: 0/2   (round 1 is the first review, not counted)",
        "Reviewed head: h3",
        f"Notes: {notes}  Plan: {notes}/plan.md  PR: 7  Base: main",
        "Researched: 0  Asked: 0",
        "Rounds:",
        "- review 1 - h3 - R1",
        "Blockers:",
        "- which log? - fact - open",
    ]


def test_a_command_before_init_exits_2_naming_init(repo: Path) -> None:
    code, _, err = run(repo, "next")

    assert code == 2
    assert err == (
        "state: no run in this worktree\n"
        "fix: state init --notes /tmp/engineer-<owner>-<repo>-<slug>\n"
    )


def test_outside_a_repo_exits_2(tmp_path: Path) -> None:
    code, _, err = run(tmp_path, "next")

    assert code == 2
    assert err.splitlines()[1] == "fix: cd <worktree>; state keeps one run per worktree"
