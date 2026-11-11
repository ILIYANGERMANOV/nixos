"""The engineer flow as data: the transition table, the `## States` steps, the
engineer's Quality rows and the brief texts quoted verbatim from its skill."""

from typing import Literal

from state.model import (
    AREAS,
    MODES,
    STATES,
    TOKENS,
    Area,
    Mode,
    ProposalMode,
    StateName,
)

# ---- The table ----------------------------------------------------------------

# `classify` names an event's arrow; most kinds are the event's own name.
type Kind = Literal[
    "started", "started-delegated", "knob", "researched", "asked", "planned",
    "proposed", "confirmed", "confirmed-replan", "adjusted", "drafted", "implemented", "refactored",
    "reviewed", "picked-loop", "picked-final", "fixed", "ci", "simplified", "raised", "blocked",
    "blocked-decision", "resolved", "ready",
]  # fmt: skip

LIVE: tuple[StateName, ...] = STATES[:-1]
# After the final fixer an implementer's slice is a CI fix: the loop's work, and
# its `implemented` stays put as a `fixed` would.
CI_FIX_STEPS: tuple[StateName, ...] = ("DraftPR", "PR")

# Every arrow but an override: (state, kind) -> target. A pair not here is an
# event the flow does not expect in that state; `state override` gets there.
TARGET: dict[tuple[StateName, Kind], StateName] = {
    ("Ctx", "started"): "Ctx",
    ("Ctx", "started-delegated"): "DraftPlan",
    **{(s, "knob"): s for s in LIVE},
    **{(s, "researched"): s for s in LIVE},
    **{(s, "raised"): s for s in LIVE},
    **{(s, "blocked"): s for s in LIVE},
    **{(s, "blocked-decision"): "Ctx" for s in LIVE},
    **{(s, "resolved"): s for s in LIVE},
    ("Ctx", "asked"): "Ctx",
    ("Ctx", "planned"): "Propose",
    ("Propose", "proposed"): "Propose",
    ("Propose", "confirmed"): "DraftPlan",
    # A re-plan from a decision: the PR exists, so it resumes at step 5.
    ("Propose", "confirmed-replan"): "Implement",
    ("Propose", "adjusted"): "Ctx",
    ("DraftPlan", "drafted"): "Implement",
    ("Implement", "implemented"): "Refactor",
    ("Refactor", "implemented"): "Refactor",
    # A fix before the refactor (a blocker the implementer left) keeps the
    # refactor and its skip guard next.
    ("Refactor", "fixed"): "Refactor",
    ("Refactor", "refactored"): "Review",
    # A late slice after the refactor: no second refactor, the first review
    # reads the whole branch.
    ("Review", "implemented"): "Review",
    # A review back stays put until the lead's picks say where it goes. One in
    # Refactor is one whose refactor the guard skipped.
    **{(s, "reviewed"): s for s in ("Refactor", "Review", "Fix", "PR")},
    ("Refactor", "picked-loop"): "Fix",
    ("Refactor", "picked-final"): "DraftPR",
    ("Review", "picked-loop"): "Fix",
    ("Review", "picked-final"): "DraftPR",
    ("Fix", "picked-loop"): "Fix",
    ("Fix", "picked-final"): "DraftPR",
    ("Fix", "fixed"): "Fix",
    ("DraftPR", "fixed"): "DraftPR",
    **{(s, "implemented"): s for s in CI_FIX_STEPS},
    ("DraftPR", "ci"): "PR",
    ("PR", "ci"): "PR",
    ("PR", "fixed"): "PR",
    # S0 runs while CI does, so it lands before or after the step moves to PR.
    ("DraftPR", "simplified"): "DraftPR",
    ("PR", "simplified"): "PR",
    ("PR", "picked-loop"): "PR",
    ("PR", "picked-final"): "PR",
    ("PR", "ready"): "Done",
}

# The `## States` block of the engineer skill, which pastes it from `state render`.
STEPS: tuple[tuple[str, str, str], ...] = (
    ("1-2", "Ctx", "research and ask on demand, any order, then a plan: 3; resolved: back to the step the decision came from"),
    ("3", "Propose", "simplify, alternative, then ask: first or second plan: 4; adjust: 2"),
    ("4", "DraftPlan", "draft PR with the plan: 5"),
    ("5", "Implement", "implement: 6"),
    ("6", "Refactor", "refactor: 7; fixed: 6"),
    ("7", "Review", "first review: rows to fix: 8; none: final fixer, 9; implemented: 7"),
    ("8", "Fix", "fix, then a `--fixes` review: 8 while rounds remain; cap: final fixer, 9"),
    ("9", "DraftPR", "simplify: 9a; notify: 10"),
    ("9a", "Simplify", "S0 fixer while CI runs: 10"),
    ("10", "PR", "green CI: ready and notify; CI issues: `review.md`'s CI fix, then CI again"),
    ("any", "blocker", "a worker's `NEEDS_DECISION`: triage in `blockers.md`"),
    ("any", "stuck", "the stuck guard above: ask"),
)  # fmt: skip

STATES_INTRO = "Each step is a state. Quality and Size skip arrows, never add them."
STATES_FOOTER = """\
Every Quality and Size keeps the quick security review, the blocker arrows,
fact-gap research and the final fixer. A re-plan from a blocker follows
your Quality row too."""

# The guards behind the engineer's Quality rows: the facts the rows below print.
PROPOSALS: dict[Mode, tuple[ProposalMode, ...]] = {
    "POC": ("simplify",),
    "Balanced": ("simplify", "alternative"),
    "Max": ("simplify", "alternative"),
}
REFACTOR_ABOVE = 100  # Balanced refactors above about this many changed lines
RE_REVIEWS: dict[Mode, int] = {"POC": 1, "Balanced": 2, "Max": 3}
FULL_REVIEW: dict[Mode, frozenset[Area]] = {
    "POC": frozenset(AREAS),
    "Balanced": frozenset({"data-model", "auth"}),
    "Max": frozenset(AREAS),
}


def areas_text(areas: frozenset[Area]) -> str:
    """`interface, data model, auth`: `AREAS`'s order, the table's words."""
    return ", ".join(a.replace("-", " ") for a in AREAS if a in areas)


# The engineer's rows of the Quality table in `quality.md`. A row a guard reads
# is printed from that guard's facts, so the two cannot drift.
QUALITY_ROWS: tuple[tuple[str, dict[Mode, str]], ...] = (
    ("Researchers", {
        "POC": "1 for all, 8 calls, notes past the hand-back limit",
        "Balanced": "up to 3, 15 calls, notes",
        "Max": "one per group, 30 calls, notes, top 5 facts re-checked",
    }),
    ("Proposals", {m: ", ".join(PROPOSALS[m]) for m in MODES}),
    ("Implement", {
        "POC": "one implementer, one happy-path proof as its test",
        "Balanced": "as planned",
        "Max": "as planned",
    }),
    ("Refactor", {
        "POC": "quick: items 1-3, no `tests.md`",
        "Balanced": f"above about {REFACTOR_ABOVE} changed lines",
        "Max": "always",
    }),
    ("Skill dry run", {"POC": "never", "Balanced": "new or rewritten skill", "Max": "any skill change"}),
    ("Re-reviews", {
        "POC": f"{RE_REVIEWS['POC']}, blockers and Not met fixed only",
        "Balanced": f"up to {RE_REVIEWS['Balanced']}",
        "Max": f"up to {RE_REVIEWS['Max']}",
    }),
    ("Full review of a fix to", {m: areas_text(FULL_REVIEW[m]) for m in MODES}),
)  # fmt: skip
QUALITY = dict(QUALITY_ROWS)

# ---- Texts the engineer skill and its references quote verbatim ---------------

STOP_RULE = """\
> A question that blocks your work and that the repo, this brief and the plan
> do not settle, or choosing differently from a decision the plan states:
> stop at once. Commit and push the work you have, if any, as a
> normal commit with no WIP marker and `Remaining: <what is left>` in its
> body, plus `(does not build yet)` when it does not build.
> Start your hand-back with `NEEDS_DECISION <question>`, then that commit, what
> you tried and the evidence paths. Spawn no researcher.
> On `Size: Trivial`, work bigger than briefed is `GREW <why>`: stop the same
> way, after committing and pushing what you have, and start your hand-back
> with that line. With a `NEEDS_DECISION`, that line comes first and `GREW`
> on the next."""

PLAN_WRONG = """\
> The plan is wrong when a finding shows a wrong approach, a requirement that
> cannot be met, scope the plan does not hold, or a data-model or auth
> redesign. Do not stop early: finish the review, then make
> `NEEDS_DECISION plan wrong: <finding>` the first line of your return, before
> the usual report. Every other finding, security included, goes in the table
> as usual."""

HANDBACK_RULE = (
    "Hand back in about 250 words, never over 300: commit, proof, what remains; "
    "anything longer goes in a notes file outside the repo, and you hand back its "
    f"path. Start your hand-back with {', '.join(TOKENS[:-1])} or {TOKENS[-1]}."
)


def resume_text(head: str) -> str:
    return (
        f"continue from commit `{head}`: its body says what remains; when it says "
        "it does not build, make it build first"
    )


# Step 3's plan question: its options, and the options with only one plan.
PLAN_OPTIONS = '"First plan", "Second plan", "Adjust"'
ONE_PLAN_OPTIONS = '"Yes, build it (Recommended)" / "No, adjust"'

# Step 4's POC label commands; delegated, both and `gh pr create` take REPO_FLAG.
POC_LABEL = ("gh label create POC --force", "gh pr edit <n> --add-label POC")
REPO_FLAG = "--repo <repo>"
DELEGATED_PR_FLAGS = f"{REPO_FLAG} --head <branch> --base <base>"

# Step 10's gates before `gh pr ready`.
READY_GATES = (
    "every review comment on the PR has a reply or a triage",
    "every open decision is triaged as `blockers.md` says",
    (
        "when the diff touches a workflow, every `secrets.*` it references, "
        "`GITHUB_TOKEN` aside, is in `gh secret list`, in `gh secret list --env <env>` "
        "for a job with an `environment:`, or in `gh secret list --org <owner>` for an "
        "org repository. A missing secret goes to the user"
    ),
)


def next_steps(pr: str, requirements: str) -> tuple[str, str, str, str]:
    """Step 10's optional next steps, each a line the user pastes."""
    return (
        f"/qa {pr}",
        f"/final-review --requirements {requirements} {pr}",
        f"/give-feedback {pr}",
        f"/address-pr-feedback {pr}",
    )


def stuck_line(why: str) -> str:
    return f"NEEDS_DECISION stuck: {why}"


def r0_text(base: str) -> str:
    return (
        "R0: the PR body describes the branch in the form `pr-description` picks, "
        f"read from `ctx diff origin/{base}`, with the full facts: any decisions made "
        "on the user's behalf, every recorded reason for an unfixed row, the "
        "decisions and considered options as one collapsed table, and "
        "`## Follow-ups`; S0 owns the shape"
    )


# R0 once S0 shortened the body: nothing rewrites it whole again.
R0_IN_PLACE = (
    "R0: edit the PR body's sections the fix changes in place, keep the S0 shape, "
    "and rerun `pr-description`'s visible_lines check"
)

S0_TEXT = (
    "S0: rewrite the PR body as `pr-description`'s `## Simplify (row S0)` section "
    "says; end your hand-back with a line `Simplified: <head sha>`"
)
