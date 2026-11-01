"""The read guard against real files and a real git repository.

`$DIR` in a table is the project, `$HOME` the home holding its skills.
"""

import os
import subprocess
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path

import pytest
from guard_harness import (
    ALLOWED,
    BLOCKED,
    FAIL_OPEN_CASES,
    Case,
    bash_event,
    guard_cases,
    run_guard,
    tool_event,
)

GUARD = os.environ["READ_GUARD"]
LARGE = 9000  # Under the limit alone, over it together.
HUGE = 20000  # Over the limit alone.

type ToolInput = dict[str, int]

BASH_CASES: list[Case[str]] = [
    (BLOCKED, "a single large file is blocked", "cat huge"),
    (ALLOWED, "a file under the limit is allowed", "cat big-a"),
    (ALLOWED, "small files read together are allowed", "cat small-a small-b"),
    (BLOCKED, "large files read together are blocked", "cat big-a big-b"),
    (BLOCKED, "a glob naming large files is blocked", "cat big-*"),
    (
        BLOCKED,
        "large files across chained cats are blocked",
        "cat big-a && cat -n big-b",
    ),
    (
        BLOCKED,
        "a large blob shown with another file is blocked",
        "git show HEAD:big-a; cat big-b",
    ),
    (
        BLOCKED,
        "git -C sizes blobs in that repository",
        "cd / && git -C $DIR show HEAD:big-a HEAD:big-a",
    ),
    (
        BLOCKED,
        "cd to an absolute path moves later reads",
        "cd $DIR/sub && cat big-c big-d",
    ),
    (
        BLOCKED,
        "cd to a relative path moves later reads",
        "cd sub && cat -n big-c; cat big-d",
    ),
    (
        ALLOWED,
        "small files after a relative cd are allowed",
        "cd sub && cat small-c small-d",
    ),
    (
        ALLOWED,
        "a cd to a missing directory is allowed",
        "cd nowhere && cat big-a big-b",
    ),
    (ALLOWED, "a commit without a path is not sized", "git show HEAD; cat big-b"),
    (
        BLOCKED,
        "missing files are skipped, the rest still count",
        "cat nope big-a big-b",
    ),
    (
        BLOCKED,
        "a path behind a denied directory is skipped, the rest still count",
        "cat big-a big-b locked/secret",
    ),
    (
        BLOCKED,
        "an over-long file name is skipped, the rest still count",
        "cat big-a big-b " + "x" * 300,
    ),
    (
        BLOCKED,
        "an unknown ~user is skipped, the rest still count",
        "cat big-a big-b ~nouser/file",
    ),
    (
        BLOCKED,
        "a ~name with no user is skipped, the rest still count",
        "cat big-a big-b ~backup.txt",
    ),
    (
        BLOCKED,
        "a cd to the previous directory keeps what was already sized",
        "cat big-a big-b; cd ~-",
    ),
    (ALLOWED, "other commands are allowed", "grep -n x big-a big-b huge"),
    (ALLOWED, "a heredoc write is allowed", "cat > out <<'EOF'\nbig-a big-b\nEOF"),
    (
        ALLOWED,
        "large files redirected to a file are allowed",
        "cat big-a big-b > combined",
    ),
    (
        ALLOWED,
        "large files appended to a file are allowed",
        "cat big-a big-b 2>/dev/null >> combined",
    ),
    (BLOCKED, "a stderr redirect still shows stdout", "cat big-a big-b 2>/dev/null"),
    (
        ALLOWED,
        "a heredoc body naming large reads is allowed",
        "cat <<EOF > notes\ncat big-a big-b\ngit show HEAD:big-a HEAD:big-a\nEOF\necho done",
    ),
    (
        BLOCKED,
        "reads after a heredoc body are still sized",
        "cat <<-EOF > notes\nbody\nEOF\ncat big-a big-b",
    ),
    (
        ALLOWED,
        "large files piped into a filter are allowed",
        "cat big-a big-b | grep -c x",
    ),
    (
        ALLOWED,
        "a blob piped into a filter is allowed",
        "git show HEAD:big-a HEAD:big-a | head",
    ),
    (
        ALLOWED,
        "large skill files read together are allowed",
        "cat ~/.claude/skills/big-skill/SKILL.md ~/.claude/skills/big-skill/references/ref.md",
    ),
    (
        ALLOWED,
        "a large skill reference is allowed",
        "cat ~/.claude/skills/big-skill/references/huge-ref.md",
    ),
    (
        ALLOWED,
        "a skill glob is allowed",
        "cd ~/.claude/skills/big-skill && cat SKILL.md references/*",
    ),
    (
        BLOCKED,
        "a skill file does not exempt another large file",
        "cat ~/.claude/skills/big-skill/SKILL.md big-a big-b",
    ),
    (
        BLOCKED,
        "a path that leaves the skills directory is sized",
        "cat ~/.claude/skills/../../work/big-a big-b",
    ),
    (
        ALLOWED,
        "instruction files read together are allowed",
        "cat AGENTS.md CLAUDE.md SKILL.md factory-instructions.md",
    ),
    (
        ALLOWED,
        "instruction files are exempt by basename anywhere",
        "cat repo-docs/CLAUDE.md repo-docs/SKILL.md",
    ),
    (
        ALLOWED,
        "skill references read together are allowed",
        "cat repo-docs/skills/custom/foo/references/a.md repo-docs/skills/bar/references/*.md",
    ),
    (ALLOWED, "a skill's source is allowed", "cat repo-docs/skills/bar/lib.py big-a"),
    (
        ALLOWED,
        "a nested skill file is allowed",
        "cat repo-docs/skills/bar/references/deep/nested.md big-a",
    ),
    (
        ALLOWED,
        "instruction blobs read together are allowed",
        "git show HEAD:repo-docs/CLAUDE.md HEAD:repo-docs/SKILL.md",
    ),
    (
        ALLOWED,
        "reference blobs read together are allowed",
        "git -C $DIR show HEAD:repo-docs/skills/custom/foo/references/a.md HEAD:repo-docs/skills/bar/references/b.md",
    ),
    (ALLOWED, "an exempt file leaves a small sibling allowed", "cat CLAUDE.md big-a"),
    (
        ALLOWED,
        "an instruction file is exempt by the name it was read under",
        "cat admin/CLAUDE.md big-a",
    ),
    (
        BLOCKED,
        "an exempt file does not exempt a source file over the limit",
        "cat CLAUDE.md huge",
    ),
    (BLOCKED, "a single large blob is blocked", "git show HEAD:huge"),
    (BLOCKED, "a cat after an assignment is blocked", "LC_ALL=C cat huge"),
    (ALLOWED, "a compound piped away is allowed", "{ cat huge; } | head"),
    (
        BLOCKED,
        "an exempt blob does not exempt a blob over the limit",
        "git show HEAD:repo-docs/CLAUDE.md HEAD:huge",
    ),
    (
        BLOCKED,
        "a skill file does not exempt a source file over the limit",
        "cat repo-docs/skills/bar/lib.py huge",
    ),
    (
        BLOCKED,
        "a file directly under skills is counted",
        "cat repo-docs/skills/default.nix big-a",
    ),
    (
        BLOCKED,
        "a directory that only ends in skills is counted",
        "cat repo-docs/notskills/bar/lib.py big-a",
    ),
    (
        BLOCKED,
        "a name that only ends like an instruction file is counted",
        "cat NOTCLAUDE.md big-a",
    ),
]

READ_CASES: list[Case[tuple[str, ToolInput]]] = [
    (BLOCKED, "a whole Read of a large file is blocked", ("$DIR/huge", {})),
    (BLOCKED, "a relative Read resolves against cwd", ("huge", {})),
    (BLOCKED, "a dotfile named like an image is sized", ("..png", {})),
    (BLOCKED, "an offset alone does not bound a Read", ("huge", {"offset": 100})),
    (
        BLOCKED,
        "a Read that leaves a skill is sized",
        ("$DIR/repo-docs/skills/bar/../../../huge", {}),
    ),
    (
        ALLOWED,
        "a limited Read of a large file is allowed",
        ("$DIR/huge", {"limit": 100}),
    ),
    (ALLOWED, "a whole Read of a small file is allowed", ("$DIR/big-a", {})),
    (
        ALLOWED,
        "a Read of a large skill reference is allowed",
        ("$HOME/.claude/skills/big-skill/references/huge-ref.md", {}),
    ),
    (
        ALLOWED,
        "a Read of a large instruction file is allowed",
        ("$DIR/instructions/CLAUDE.md", {}),
    ),
    (ALLOWED, "a Read of an image is allowed", ("$DIR/huge.png", {})),
    (ALLOWED, "a Read of a PDF is allowed, in any case", ("$DIR/huge.PDF", {})),
    (ALLOWED, "a Read of a missing file is allowed", ("$DIR/nope", {})),
]

RAW_CASES: list[Case[str]] = [
    (
        ALLOWED,
        "a Read without a path is allowed",
        '{"tool_name": "Read", "tool_input": {}}',
    ),
]


@dataclass(frozen=True, slots=True)
class Project:
    home: Path
    root: Path

    def expand(self, text: str) -> str:
        return text.replace("$DIR", str(self.root)).replace("$HOME", str(self.home))

    def decide(self, event: str) -> subprocess.CompletedProcess[str]:
        return run_guard([GUARD], event, os.environ | {"HOME": str(self.home)})

    def bash(self, command: str) -> subprocess.CompletedProcess[str]:
        return self.decide(bash_event(self.expand(command), cwd=str(self.root)))

    def read(
        self, file_path: str, tool_input: ToolInput
    ) -> subprocess.CompletedProcess[str]:
        return self.decide(
            tool_event(
                "Read",
                {"file_path": self.expand(file_path), **tool_input},
                cwd=str(self.root),
            )
        )


@guard_cases(BASH_CASES)
def test_bash_call(project: Project, want: int, given: str) -> None:
    assert project.bash(given).returncode == want


@guard_cases(READ_CASES)
def test_read_call(project: Project, want: int, given: tuple[str, ToolInput]) -> None:
    assert project.read(*given).returncode == want


@guard_cases(RAW_CASES + FAIL_OPEN_CASES)
def test_raw_input(project: Project, want: int, given: str) -> None:
    assert project.decide(given).returncode == want


def test_a_bash_block_carries_the_hint(project: Project) -> None:
    result = project.bash("cat big-a big-b")

    assert result.returncode == BLOCKED
    assert "grep -n first" in result.stderr


def test_a_read_block_carries_the_hint(project: Project) -> None:
    result = project.read("$DIR/huge", {})

    assert result.returncode == BLOCKED
    assert "offset and limit" in result.stderr


@pytest.fixture(scope="module")
def project(tmp_path_factory: pytest.TempPathFactory) -> Iterator[Project]:
    home = tmp_path_factory.mktemp("home")
    root = home / "work"
    sized(
        LARGE,
        root,
        "big-a",
        "big-b",
        "sub/big-c",
        "sub/big-d",
        "AGENTS.md",
        "CLAUDE.md",
        "SKILL.md",
        "factory-instructions.md",
        "NOTCLAUDE.md",
        "admin/hm_CLAUDE.md",
        "skills-store/big-skill/SKILL.md",
        "skills-store/big-skill/references/ref.md",
        "repo-docs/AGENTS.md",
        "repo-docs/CLAUDE.md",
        "repo-docs/SKILL.md",
        "repo-docs/factory-instructions.md",
        "repo-docs/notskills/bar/lib.py",
        "repo-docs/skills/default.nix",
        "repo-docs/skills/custom/foo/references/a.md",
        "repo-docs/skills/bar/lib.py",
        "repo-docs/skills/bar/references/b.md",
        "repo-docs/skills/bar/references/deep/nested.md",
    )
    sized(
        HUGE,
        root,
        "huge",
        "huge.png",
        "huge.PDF",
        "..png",
        "instructions/CLAUDE.md",
        "skills-store/big-skill/references/huge-ref.md",
    )
    sized(1, root, "small-a", "small-b", "sub/small-c", "sub/small-d")
    (root / "admin/CLAUDE.md").symlink_to("hm_CLAUDE.md")
    skills = home / ".claude/skills"
    skills.mkdir(parents=True)
    (skills / "big-skill").symlink_to(root / "skills-store/big-skill")
    commit(root, "big-a", "small-a", "huge", "repo-docs")
    locked = root / "locked"
    locked.mkdir(mode=0o000)
    yield Project(home, root)
    locked.chmod(0o755)


def sized(size: int, root: Path, *paths: str) -> None:
    for path in paths:
        file = root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        _ = file.write_bytes(bytes(size))


def commit(root: Path, *paths: str) -> None:
    def git(*args: str) -> None:
        _ = subprocess.run(["git", *args], cwd=root, check=True)

    git("init", "--quiet")
    git("add", *paths)
    git(
        "-c",
        "user.name=check",
        "-c",
        "user.email=check@example.com",
        "commit",
        "--quiet",
        "-m",
        "init",
    )
