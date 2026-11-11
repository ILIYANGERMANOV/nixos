"""The effects on temp git repos: the log on disk, the notes pointer, the git
facts and every command run end to end."""

import shutil
import tempfile
from pathlib import Path

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from state.core import NoPr, Pr, Unavailable
from state.effects import Loaded, parse_pr_view, read_log, sync
from state.model import Failure, Ready
from state.state_fixtures import (
    PR,
    GitHub,
    commit,
    first_line,
    git,
    log_of,
    make_repo,
    ok,
    older_log,
    run,
    to_draft,
    to_implement,
    types,
)

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
        ("record", "drafted", PR, "main", "feature"),
        ("record", "implemented"),
        ("record", "bogus"),
        ("override", "PR", "jump"),
    ]
)


@settings(deadline=None, max_examples=25)
@given(st.lists(COMMANDS, min_size=1, max_size=8))
def test_effects_the_log_is_append_only_with_a_dense_seq_from_1(
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
            # A refusal appends the one `refused` line that tells of it.
            assert len(appended) == (len(reported) if code == 0 else 1)
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

    out = ok(repo, "record", "drafted", PR, "main", "feature")

    assert out == "recorded 5 defaulted -> Implement\nrecorded 6 drafted -> Implement\n"
    assert "Quality: Balanced (defaulted)" in ok(repo, "show")


def test_an_event_off_the_table_exits_2_and_appends_one_refused(
    repo: Path, tmp_path: Path
) -> None:
    _ = ok(repo, "init", "--notes", str(tmp_path / "notes"))

    code, _, err = run(repo, "record", "ready", PR)

    message, fix = err.splitlines()
    assert code == 2
    assert message == "state record: 'ready' is not an arrow out of Ctx"
    assert [line["event"] for line in log_of(tmp_path / "notes")][1:] == [
        {
            "type": "refused",
            "message": "'ready' is not an arrow out of Ctx",
            "fix": fix.removeprefix("fix: "),
        }
    ]


@pytest.mark.parametrize("view", ["next", "show"])
def test_a_view_after_a_refusal_starts_with_the_warning_and_its_fix(
    repo: Path, tmp_path: Path, view: str
) -> None:
    _ = ok(repo, "init", "--notes", str(tmp_path / "notes"))
    _, _, err = run(repo, "record", "ready", PR)

    out = ok(repo, view)

    assert out.splitlines()[:2] == [
        "WARN refused, not recorded: 'ready' is not an arrow out of Ctx",
        err.splitlines()[1],
    ]


@pytest.mark.parametrize(
    "accepted", [("record", "researched"), ("override", "Ctx", "start over")]
)
def test_an_accepted_event_or_an_override_clears_the_warning(
    repo: Path, tmp_path: Path, accepted: tuple[str, ...]
) -> None:
    _ = ok(repo, "init", "--notes", str(tmp_path / "notes"))
    _ = run(repo, "record", "ready", PR)
    _ = ok(repo, *accepted)

    assert "WARN" not in ok(repo, "next") + ok(repo, "show")


def test_a_later_refusal_replaces_the_warning(repo: Path, tmp_path: Path) -> None:
    _ = ok(repo, "init", "--notes", str(tmp_path / "notes"))
    _ = run(repo, "record", "ready", PR)
    _ = run(repo, "record", "bogus")

    out = ok(repo, "next")

    assert [line for line in out.splitlines() if line.startswith("WARN")] == [
        "WARN refused, not recorded: state record: no event 'bogus'"
    ]


def test_drafted_takes_the_pr_url_not_its_number(repo: Path, tmp_path: Path) -> None:
    _ = ok(repo, "init", "--notes", str(tmp_path / "notes"))

    code, _, err = run(repo, "record", "drafted", "7", "main", "feature")

    assert code == 2
    assert "url '7' is not a PR URL, https://<host>/<owner>/<repo>/pull/<n>" in err
    assert types(tmp_path / "notes")[-1] == "refused"


def test_override_moves_the_state_and_next_advises_its_arrow(
    repo: Path, tmp_path: Path
) -> None:
    _ = ok(repo, "init", "--notes", str(tmp_path / "notes"))

    out = ok(repo, "override", "Implement", "the plan is in the issue")

    assert out == "recorded 2 overridden -> Implement\n"
    assert first_line(ok(repo, "next")) == "SPAWN implementer"


def test_handback_fixer_records_blocked_then_fixed(repo: Path, tmp_path: Path) -> None:
    notes = tmp_path / "notes"
    to_implement(repo, notes)
    _ = ok(repo, "record", "implemented")
    _ = ok(repo, "record", "refactored")
    _ = ok(repo, "handback", "review-lead", stdin="x\nReviewed head: abc\n")
    _ = ok(repo, "record", "picked", "--row", "R1")

    blocked = ok(
        repo, "handback", "fixer", "--kind", "fact", stdin="NEEDS_DECISION q?\n"
    )
    fixed = ok(repo, "handback", "fixer", stdin="READY\n")

    assert (blocked, fixed) == (
        "recorded 11 blocked -> Fix\n",
        "recorded 12 fixed -> Fix\n",
    )
    assert log_of(notes)[9]["event"] == {
        "type": "picked",
        "rows": ["R1"],
        "verdicts": [],
    }


def test_next_skips_the_refactor_on_a_small_balanced_diff(
    repo: Path, tmp_path: Path
) -> None:
    to_implement(repo, tmp_path / "notes")
    _ = commit(repo, {"b.txt": "x\n" * 60, "flake.lock": "y\n" * 500}, "work")
    _ = ok(repo, "record", "implemented")

    out = ok(repo, "next")

    assert first_line(out) == "SPAWN review-lead"
    assert "  refactor skipped: 60 changed lines, Balanced" in out.splitlines()


def test_next_refactors_a_large_balanced_diff_and_dry_runs_a_new_skill(
    repo: Path, tmp_path: Path
) -> None:
    to_implement(repo, tmp_path / "notes")
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
    to_implement(repo, notes)
    _ = ok(repo, "record", "implemented", "h1")
    _ = ok(repo, "record", "refactored", "h2")
    _ = ok(repo, "record", "reviewed", "h3")
    _ = ok(repo, "record", "picked", "--row", "R1")
    _ = ok(repo, "record", "blocked", "fact", "fixer", "which log?")

    out = ok(repo, "show")

    assert out.splitlines() == [
        "Step: Fix",
        "Head: h3",
        "Quality: Balanced",
        "Size: Normal",
        "Re-review: 0/2   (round 1 is the first review, not counted)",
        "Reviewed head: h3",
        "Simplified: -",
        f"Notes: {notes}  Plan: {notes}/plan.md  PR: {PR}  Base: main",
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


def test_a_pointer_to_a_deleted_log_is_no_run(repo: Path, tmp_path: Path) -> None:
    notes = tmp_path / "notes"
    _ = ok(repo, "init", "--notes", str(notes))
    shutil.rmtree(notes)
    fresh = tmp_path / "fresh"
    fresh.mkdir()

    assert run(repo, "show") == run(make_repo(fresh), "show")


def test_outside_a_repo_exits_2(tmp_path: Path) -> None:
    code, _, err = run(tmp_path, "next")

    assert code == 2
    assert err.splitlines()[1] == "fix: cd <worktree>; state keeps one run per worktree"


# ---- The PR on GitHub ---------------------------------------------------------------

PR_JSON = (
    '{"baseRefName":"main","headRefName":"feature","isDraft":true,'
    f'"state":"OPEN","url":"{PR}"}}\n'
)


@pytest.mark.parametrize(
    ("code", "stdout", "stderr", "read"),
    [
        pytest.param(
            0, PR_JSON, "", Pr(PR, "main", "feature", draft=True, state="OPEN"),
            id="a PR",
        ),
        pytest.param(
            1, "", 'no pull requests found for branch "main"\n', NoPr(),
            id="no PR for the branch",
        ),
        pytest.param(
            1, "", "error connecting to api.github.com\ncheck your internet\n",
            Unavailable("gh pr view: error connecting to api.github.com"),
            id="offline",
        ),
        pytest.param(4, "", "", Unavailable("gh pr view: exit 4"), id="no stderr"),
        pytest.param(
            0, '{"url":"x"}', "", Unavailable('gh pr view printed no PR: {"url":"x"}'),
            id="another shape",
        ),
    ],
)  # fmt: skip
def test_gh_pr_view_reads_a_pr_none_or_why_not(
    code: int, stdout: str, stderr: str, read: Pr | NoPr | Unavailable
) -> None:
    assert parse_pr_view(code, stdout, stderr) == read


def test_next_records_the_pr_opened_for_the_branch(repo: Path, tmp_path: Path) -> None:
    to_draft(repo, tmp_path / "notes")

    out = ok(repo, "next")

    assert out.startswith("recorded 6 drafted -> Implement\nSPAWN implementer\n")


def test_next_with_no_pr_yet_advises_creating_it(
    repo: Path, tmp_path: Path, github: GitHub
) -> None:
    to_draft(repo, tmp_path / "notes")
    github.clear()

    assert first_line(ok(repo, "next")) == "RUN gh pr create --draft"


def test_next_with_github_down_works_from_the_log_and_says_so(
    repo: Path, tmp_path: Path, github: GitHub
) -> None:
    to_implement(repo, tmp_path / "notes")
    github.down("error connecting to api.github.com")

    out = ok(repo, "next")

    assert out.splitlines()[:2] == [
        "PR sync skipped - gh pr view: error connecting to api.github.com",
        "SPAWN implementer",
    ]


def test_a_sync_the_flow_refuses_is_told_and_appends_nothing(
    repo: Path, tmp_path: Path
) -> None:
    notes = tmp_path / "notes"
    _ = ok(repo, "init", "--notes", str(notes))
    log = notes / "events.jsonl"
    before = log.read_text()
    match read_log(log):
        case Failure() as failure:
            raise AssertionError(failure)
        case lines, state:
            pass

    synced = sync(Loaded(log, lines, state), (Ready(PR),), repo)

    assert first_line(synced.told) == "PR sync: 'ready' is not an arrow out of Ctx"
    assert (synced.lines, synced.state) == (lines, state)
    assert log.read_text() == before


def test_show_on_another_branch_says_the_hooks_are_silent(
    repo: Path, tmp_path: Path
) -> None:
    to_implement(repo, tmp_path / "notes")
    _ = git(repo, "switch", "--quiet", "--create", "other")

    out = ok(repo, "show")

    assert out.splitlines()[:2] == [
        "state hooks: silent - HEAD is on other, the run is bound to feature",
        "Step: Implement",
    ]


def test_show_of_a_merged_pr_says_the_hooks_are_silent(
    repo: Path, tmp_path: Path, github: GitHub
) -> None:
    to_implement(repo, tmp_path / "notes")
    github.open(draft=False, state="MERGED")

    out = ok(repo, "show")

    assert first_line(out) == f"state hooks: silent - PR {PR} is merged"


def test_show_of_a_log_an_older_state_wrote_says_the_hooks_are_silent(
    repo: Path, tmp_path: Path
) -> None:
    notes = tmp_path / "notes"
    to_implement(repo, notes)
    older_log(notes)

    code, _, err = run(repo, "show")

    assert code == 2
    assert err.splitlines()[0].endswith(":6: branch is not a non-empty string")
    assert err.rstrip().endswith("the state hooks stay silent until it parses")
