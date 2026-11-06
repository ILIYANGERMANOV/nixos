"""The prose guards: the flow's texts are the engineer skill's, verbatim."""

from pathlib import Path

from core import render
from state_fixtures import ok, to_impl

ROOT = Path(__file__).resolve().parents[3]
SKILL = ROOT / "programs/agents/skills/custom/engineer/SKILL.md"
BLOCKERS = ROOT / "programs/agents/skills/custom/engineer/references/blockers.md"
QUALITY_MD = ROOT / "programs/agents/instructions/topics/quality.md"


# ---- Prose guard ------------------------------------------------------------------


def states_block(skill: str) -> str:
    """`## States` up to the next `## ` heading, its trailing blank line dropped."""
    start = skill.index("## States\n")
    end = skill.index("\n## ", start)
    return skill[start:end]


def test_prose_guard_the_skills_states_block_is_state_render() -> None:
    block = states_block(SKILL.read_text())

    assert render().startswith(block + "\n"), (
        f"paste `state render`'s States block into {SKILL}:\n\n{render()}"
    )


def test_prose_guard_the_engineers_quality_rows_are_lines_of_quality_md_in_order() -> (
    None
):
    rows = render()[len(states_block(SKILL.read_text())) + 1 :].splitlines()
    lines = QUALITY_MD.read_text().splitlines()

    found = [lines.index(row) if row in lines else -1 for row in rows]

    assert -1 not in found, f"paste these rows into {QUALITY_MD}:\n\n" + "\n".join(rows)
    assert found == sorted(found)


def stop_rule_of(blockers: str) -> str:
    """The quoted paragraph under `## The stop rule`."""
    section = blockers.split("## The stop rule\n", 1)[1]
    quoted = section.split("\n\n")[1]
    assert quoted.startswith("> ")
    return quoted


def test_brief_refactorer_holds_the_mechanics_and_the_stop_rule_verbatim(
    repo: Path, tmp_path: Path
) -> None:
    to_impl(repo, tmp_path / "notes")

    out = ok(repo, "brief", "refactorer")

    lines = out.splitlines()
    assert lines[:5] == [
        "run `refactor` with: Quality: Balanced",
        "Size: Normal",
        f"Worktree: {repo} (every command runs here)",
        "Base: origin/main",
        f"Plan: {tmp_path / 'notes'}/plan.md",
    ]
    assert stop_rule_of(BLOCKERS.read_text()) in out
    assert lines[-1].startswith("Hand back in about 250 words, never over 300")


def test_brief_review_lead_gets_the_plan_wrong_line_not_the_stop_rule(
    repo: Path, tmp_path: Path
) -> None:
    to_impl(repo, tmp_path / "notes")

    out = ok(repo, "brief", "review-lead")

    assert "`NEEDS_DECISION plan wrong: <finding>`" in out
    assert stop_rule_of(BLOCKERS.read_text()) not in out
