"""The prose guards: the flow's texts are the engineer skill's, verbatim."""

import re
from pathlib import Path

from state.core import render
from state.flow import (
    DELEGATED_PR_FLAGS,
    ONE_PLAN_OPTIONS,
    PLAN_OPTIONS,
    PLAN_WRONG,
    POC_LABEL,
    READY_GATES,
    REPO_FLAG,
    STOP_RULE,
    next_steps,
    resume_text,
    stuck_line,
)
from state.model import WORKERS
from state.state_fixtures import ok, to_impl

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
    return quote_after(blockers, "## The stop rule\n")


def quote_after(doc: str, marker: str) -> str:
    """The first `> ` paragraph after `marker`."""
    after = doc.split(marker, 1)[1]
    return next(p for p in after.split("\n\n") if p.startswith("> "))


def section(doc: str, heading: str) -> str:
    """`heading`'s text up to the next `##` or `###` heading, its lines joined
    with single spaces, so a quote matches however the prose wraps it."""
    start = doc.index(f"\n{heading}\n")
    end = re.search(r"\n#{2,3} ", doc[start + 1 :])
    return flat(doc[start : start + 1 + end.start()] if end else doc[start:])


def flat(text: str) -> str:
    return " ".join(text.split())


def test_prose_guard_the_stop_rule_is_blockers_md_verbatim() -> None:
    assert stop_rule_of(BLOCKERS.read_text()) == STOP_RULE


def test_prose_guard_the_plan_wrong_line_is_blockers_md_verbatim() -> None:
    assert quote_after(BLOCKERS.read_text(), "gets this line instead") == PLAN_WRONG


def test_prose_guard_blockers_md_resume_quotes_resume_text() -> None:
    resume = section(BLOCKERS.read_text(), "## Triage")

    assert f'"{resume_text("<sha>")}"' in resume


def test_prose_guard_step_3_asks_with_states_options() -> None:
    step = section(SKILL.read_text(), "### 3. Confirm the plan")

    assert f"{PLAN_OPTIONS}," in step
    assert f"{ONE_PLAN_OPTIONS}." in step


def test_prose_guard_step_4_and_delegated_hold_states_pr_commands() -> None:
    skill = SKILL.read_text()
    step, delegated = (
        section(skill, "### 4. Open a draft PR"),
        section(skill, "## Delegated"),
    )

    assert all(f"`{command}`" in step for command in POC_LABEL)
    assert f"`{DELEGATED_PR_FLAGS}`" in delegated
    assert f"both POC label commands `{REPO_FLAG}`" in delegated


def test_prose_guard_step_10_lists_states_ready_gates_and_next_steps() -> None:
    step = section(SKILL.read_text(), "### 10. Hand over")

    assert all(flat(gate) in step for gate in READY_GATES)
    assert all(f"`{line}`" in step for line in next_steps("<PR>", "<path>"))


def test_prose_guard_the_stuck_guard_quotes_states_stuck_line() -> None:
    assert f"`{stuck_line('<check or row>')}`" in flat(SKILL.read_text())


def test_prose_guard_the_skill_names_exactly_the_roles_state_handback_takes() -> None:
    roles = f"{', '.join(WORKERS[:-1])} and {WORKERS[-1]}"

    assert f"paste each {roles} hand-back into `state handback <role>`" in flat(
        SKILL.read_text()
    )


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
