"""`ctx` on temp git repos: what it prints, what the folder holds, and caching."""

import subprocess
from pathlib import Path

import pytest
from ctx import Files, main, materialize, repo_slug

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


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    """main has one commit; branch `feature` adds b.txt and edits a.txt."""
    path = tmp_path / "repo"
    path.mkdir()
    _ = git(path, "init", "--quiet", "--initial-branch=main")
    _ = git(path, "remote", "add", "origin", "git@github.com:owner/name.git")
    _ = commit(path, {"a.txt": "one\ntwo\n", ".gitignore": "*.log\n"}, "base")
    _ = git(path, "switch", "--quiet", "--create", "feature")
    _ = commit(path, {"a.txt": "one\nTWO\n", "b.txt": "new\n"}, "feature work")
    return path


def run(
    repo: Path, store: Path, capsys: pytest.CaptureFixture[str], *argv: str
) -> tuple[int, str, str]:
    code = main(list(argv), repo, store)
    out, err = capsys.readouterr()
    return code, out, err


def folder_of(out: str) -> Path:
    return Path(out.splitlines()[0])


def files_in(folder: Path) -> dict[str, bytes]:
    return {path.name: path.read_bytes() for path in sorted(folder.iterdir())}


def test_diff_prints_the_folder_alone_on_line_one_then_the_manifest(
    repo: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    code, out, err = run(repo, tmp_path / "store", capsys, "diff", "main", "HEAD")

    lines = out.splitlines()
    assert (code, err) == (0, "")
    assert folder_of(out).parent == tmp_path / "store" / "owner-name" / "diff"
    assert lines[1].startswith("diff main (merge-base ") and lines[1].endswith(
        ") .. HEAD " + git(repo, "rev-parse", "--short=7", "HEAD").strip()
    )
    assert lines[2] == "2 files, +2 -1, cached: no"
    assert lines[-1] == "read: index, then sed -n '<first>,<last>p' diff per file"


def test_manifest_counts_each_files_lines(
    repo: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    _, out, _ = run(repo, tmp_path / "store", capsys, "diff", "main", "HEAD")

    folder = folder_of(out)
    rows = {line.split()[0]: int(line.split()[1]) for line in out.splitlines()[3:-1]}
    assert rows == {
        name: len((folder / name).read_text().splitlines()) for name in rows
    }
    assert set(rows) == {"index", "status", "stat", "log", "diff"}


def test_folder_holds_the_branch_diff_its_status_and_log(
    repo: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    _, out, _ = run(repo, tmp_path / "store", capsys, "diff", "main", "HEAD")

    folder = folder_of(out)
    assert (folder / "status").read_text() == "M\ta.txt\nA\tb.txt\n"
    assert (folder / "log").read_text().split(maxsplit=1)[1] == "feature work\n"
    assert "+TWO" in (folder / "diff").read_text()


def test_index_points_at_each_files_lines_in_diff(
    repo: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    _, out, _ = run(repo, tmp_path / "store", capsys, "diff", "main", "HEAD")

    folder = folder_of(out)
    diff = (folder / "diff").read_text().splitlines()
    for line in (folder / "index").read_text().splitlines():
        path, first, last = line.rsplit(" ", 2)
        section = diff[int(first) - 1 : int(last)]
        assert section[0] == f"diff --git a/{path} b/{path}"
        assert not any(row.startswith("diff --git ") for row in section[1:])
    assert int((folder / "index").read_text().splitlines()[-1].split()[-1]) == len(diff)


def test_index_and_line_counts_split_on_newlines_only(
    repo: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    _ = commit(repo, {"c.txt": "one\fpage\x85two\u2028end\n"}, "odd separators")

    _, out, _ = run(repo, tmp_path / "store", capsys, "diff", "main", "HEAD")

    folder = folder_of(out)
    newlines = (folder / "diff").read_bytes().count(b"\n")
    rows = {line.split()[0]: int(line.split()[1]) for line in out.splitlines()[3:-1]}
    last = (folder / "index").read_text().splitlines()[-1].split()
    assert (last[0], int(last[-1]), rows["diff"]) == ("c.txt", newlines, newlines)


def test_a_file_that_is_not_utf8_lands_in_the_folder_byte_for_byte(
    repo: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    _ = (repo / "latin1.txt").write_bytes("caf\xe9\n".encode("latin-1"))
    _ = git(repo, "add", "latin1.txt")
    _ = git(repo, "commit", "--quiet", "--message=latin-1")

    code, out, err = run(repo, tmp_path / "store", capsys, "diff", "main", "HEAD")

    assert (code, err) == (0, "")
    assert b"+caf\xe9\n" in (folder_of(out) / "diff").read_bytes()


def test_second_call_builds_nothing_and_gives_identical_files(
    repo: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    store = tmp_path / "store"
    _, first, _ = run(repo, store, capsys, "diff", "main")
    before = files_in(folder_of(first))

    _, second, _ = run(repo, store, capsys, "diff", "main")

    assert folder_of(second) == folder_of(first)
    assert files_in(folder_of(second)) == before
    assert second.splitlines()[2].endswith("cached: yes")


def test_a_build_that_loses_the_rename_keeps_the_winners_folder(tmp_path: Path) -> None:
    store = tmp_path / "store"
    winner: Files = {"diff": b"winner\n"}

    def build_while_another_wins() -> Files:
        _, _ = materialize(store, "key", lambda: winner)
        return {"diff": b"loser\n"}

    folder, _ = materialize(store, "key", build_while_another_wins)

    assert folder == store / "key"
    assert (folder / "diff").read_text() == "winner\n"
    assert [p.name for p in store.iterdir()] == ["key"]


def test_work_tree_snapshot_has_staged_unstaged_and_untracked_but_not_ignored(
    repo: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    _ = (repo / "staged.txt").write_text("s\n")
    _ = git(repo, "add", "staged.txt")
    _ = (repo / "a.txt").write_text("unstaged\n")
    _ = (repo / "untracked.txt").write_text("u\n")
    _ = (repo / "noise.log").write_text("ignored\n")
    index_before = git(repo, "ls-files", "--stage")

    _, out, _ = run(repo, tmp_path / "store", capsys, "diff", "main")

    status = (folder_of(out) / "status").read_text()
    assert status == "M\ta.txt\nA\tb.txt\nA\tstaged.txt\nA\tuntracked.txt\n"
    assert (
        out.splitlines()[1].endswith(")") and "work tree (HEAD " in out.splitlines()[1]
    )
    assert git(repo, "ls-files", "--stage") == index_before


def test_a_work_tree_change_is_a_new_folder(
    repo: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    store = tmp_path / "store"
    _, first, _ = run(repo, store, capsys, "diff", "main")
    _ = (repo / "b.txt").write_text("changed\n")

    _, second, _ = run(repo, store, capsys, "diff", "main")

    assert folder_of(second) != folder_of(first)


def test_delta_on_an_ancestor_diffs_from_prev_without_merge_base(
    repo: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    prev = git(repo, "rev-parse", "HEAD").strip()
    _ = commit(repo, {"c.txt": "c\n"}, "fix")

    _, out, _ = run(repo, tmp_path / "store", capsys, "delta", prev, "HEAD")

    folder = folder_of(out)
    assert folder.parent.name == "delta"
    assert (folder / "status").read_text() == "A\tc.txt\n"
    assert (folder / "ancestor").read_text() == "yes\n"
    assert out.splitlines()[1].endswith("ancestor: yes")


def test_delta_after_a_rewrite_says_ancestor_no_and_still_succeeds(
    repo: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    prev = git(repo, "rev-parse", "HEAD").strip()
    _ = git(repo, "commit", "--quiet", "--amend", "--message=rewritten")

    code, out, _ = run(repo, tmp_path / "store", capsys, "delta", prev, "HEAD")

    assert code == 0
    assert (folder_of(out) / "ancestor").read_text() == "no\n"
    assert "ancestor: no (history rewritten" in out.splitlines()[1]


def test_an_empty_diff_has_empty_files_and_zero_counts(
    repo: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    code, out, _ = run(repo, tmp_path / "store", capsys, "delta", "HEAD", "HEAD")

    assert code == 0
    assert out.splitlines()[2] == "0 files, +0 -0, cached: no"
    assert (folder_of(out) / "diff").read_text() == ""


def test_an_unknown_ref_exits_2_with_a_fix_line(
    repo: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    code, out, err = run(repo, tmp_path / "store", capsys, "diff", "origin/mian")

    assert (code, out) == (2, "")
    assert err.splitlines() == [
        "ctx diff: unknown ref 'origin/mian' - not a commit in this repo",
        "fix: git fetch origin main && ctx diff origin/main",
    ]


def test_an_unknown_prev_exits_2_and_points_at_a_whole_branch_review(
    repo: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    code, _, err = run(repo, tmp_path / "store", capsys, "delta", "1a2b3c4")

    assert code == 2
    assert err.splitlines()[-1].startswith("fix: ") and "ctx diff origin/main" in err


def test_outside_a_repo_exits_2(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    code, _, err = run(tmp_path, tmp_path / "store", capsys, "diff", "main")

    assert code == 2
    assert err.startswith("ctx: not inside a git work tree")


@pytest.mark.parametrize("argv", [["dif", "main"], ["diff"], ["delta", "a", "b", "c"]])
def test_bad_usage_exits_2_with_a_fix_line(
    argv: list[str], tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    code, out, err = run(tmp_path, tmp_path / "store", capsys, *argv)

    assert (code, out) == (2, "")
    assert err.splitlines()[-1].startswith("fix: ")


@pytest.mark.parametrize("argv", [[], ["help"], ["-h"], ["diff", "main", "--help"]])
def test_help_leads_with_examples_and_exits_0(
    argv: list[str], tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    code, out, _ = run(tmp_path, tmp_path / "store", capsys, *argv)

    assert code == 0
    assert out.startswith("ctx - ") and "ctx diff origin/main" in out


@pytest.mark.parametrize(
    ("url", "slug"),
    [
        ("git@github.com:owner/name.git", "owner-name"),
        ("https://github.com/owner/name", "owner-name"),
        ("https://github.com/owner/name.git/", "owner-name"),
        (None, "top"),
        ("name", "top"),
    ],
)
def test_repo_slug_is_owner_and_name_else_the_folder(
    url: str | None, slug: str
) -> None:
    assert repo_slug(url, Path("/x/top")) == slug


def test_a_store_another_account_owns_is_refused(
    repo: Path,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr("os.getuid", lambda: tmp_path.stat().st_uid + 1)

    code, out, err = run(repo, tmp_path / "store", capsys, "diff", "main")

    assert (code, out) == (1, "")
    assert "belongs to another account" in err
