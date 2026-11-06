"""The engineer flow as data: the transition table, the `## States` steps, the
engineer's Quality rows and the brief texts quoted verbatim from its skill."""

from typing import Literal

from state.model import AREAS, STATES, TOKENS, Area, Mode, ProposalMode, StateName

# ---- The table ----------------------------------------------------------------

# `classify` names an event's arrow; most kinds are the event's own name.
type Kind = Literal[
    "started", "started-delegated", "knob", "researched", "asked", "planned",
    "proposed", "confirmed", "confirmed-replan", "adjusted", "drafted", "implemented", "refactored",
    "reviewed-loop", "reviewed-final", "fixed", "ci", "blocked", "blocked-decision",
    "resolved", "ready",
]  # fmt: skip

LIVE: tuple[StateName, ...] = STATES[:-1]

# Every arrow but an override: (state, kind) -> target. A pair not here is an
# event the flow does not expect in that state; `state override` gets there.
TARGET: dict[tuple[StateName, Kind], StateName] = {
    ("Ctx", "started"): "Ctx",
    ("Ctx", "started-delegated"): "DraftPlan",
    **{(s, "knob"): s for s in LIVE},
    **{(s, "researched"): s for s in LIVE},
    **{(s, "blocked"): s for s in LIVE},
    **{(s, "blocked-decision"): "Ctx" for s in LIVE},
    **{(s, "resolved"): s for s in LIVE},
    ("Ctx", "asked"): "Ctx",
    ("Ctx", "planned"): "Prop",
    ("Prop", "proposed"): "Prop",
    ("Prop", "confirmed"): "DraftPlan",
    # A re-plan from a decision: the PR exists, so it resumes at step 5.
    ("Prop", "confirmed-replan"): "Impl",
    ("Prop", "adjusted"): "Ctx",
    ("DraftPlan", "drafted"): "Impl",
    ("Impl", "implemented"): "Impl'",
    ("Impl'", "implemented"): "Impl'",
    ("Impl'", "refactored"): "ImplR",
    # A review in Impl' is one whose refactor the guard skipped.
    ("Impl'", "reviewed-loop"): "Impl''",
    ("Impl'", "reviewed-final"): "DraftPR",
    ("ImplR", "reviewed-loop"): "Impl''",
    ("ImplR", "reviewed-final"): "DraftPR",
    ("Impl''", "reviewed-loop"): "Impl''",
    ("Impl''", "reviewed-final"): "DraftPR",
    ("Impl''", "fixed"): "Impl''",
    ("DraftPR", "fixed"): "DraftPR",
    ("DraftPR", "ci"): "PR",
    ("PR", "ci"): "PR",
    ("PR", "fixed"): "PR",
    ("PR", "reviewed-loop"): "PR",
    ("PR", "reviewed-final"): "PR",
    ("PR", "ready"): "Done",
}

# The `## States` block of the engineer skill, which pastes it from `state render`.
STEPS: tuple[tuple[str, str, str], ...] = (
    ("1-2", "Ctx", "research and ask on demand, any order, then a plan: 3"),
    ("3", "Prop", "simplify, alternative, then ask: first or second plan: 4; adjust: 2"),
    ("4", "DraftPlan", "draft PR with the plan: 5"),
    ("5", "Impl", "implement: 6"),
    ("6", "Impl'", "refactor: 7"),
    ("7", "ImplR", "first review: rows to fix: 8; none: final fixer, 9"),
    ("8", "Impl''", "fix, then a `--fixes` review: 8 while rounds remain; cap: final fixer, 9"),
    ("9", "DraftPR", "notify: 10"),
    ("10", "PR", "green CI: ready and notify; CI issues: `review.md`'s CI fix, then CI again"),
    ("any", "blocker", "a worker's `NEEDS_DECISION`: triage in `blockers.md`"),
    ("any", "stuck", "the stuck guard above: ask"),
)  # fmt: skip

STATES_INTRO = "Each step is a state. Quality and Size skip arrows, never add them."
STATES_FOOTER = """\
Every Quality and Size keeps the quick security review, the blocker arrows,
fact-gap research and the final fixer. A re-plan from a blocker follows
your Quality row too."""

# The engineer's rows of the Quality table in `quality.md`, as the guards read them.
QUALITY_ROWS: tuple[tuple[str, dict[Mode, str]], ...] = (
    ("Researchers", {
        "POC": "1 for all, 8 calls, notes past the hand-back limit",
        "Balanced": "up to 3, 15 calls, notes",
        "Max": "one per group, 30 calls, notes, top 5 facts re-checked",
    }),
    ("Proposals", {"POC": "simplify", "Balanced": "simplify, alternative", "Max": "simplify, alternative"}),
    ("Implement", {
        "POC": "one implementer, one happy-path proof as its test",
        "Balanced": "as planned",
        "Max": "as planned",
    }),
    ("Refactor", {
        "POC": "quick: items 1-3, no `tests.md`",
        "Balanced": "above about 100 changed lines",
        "Max": "always",
    }),
    ("Skill dry run", {"POC": "never", "Balanced": "new or rewritten skill", "Max": "any skill change"}),
    ("Re-reviews", {"POC": "1, blockers and Not met fixed only", "Balanced": "up to 2", "Max": "up to 3"}),
    ("Full review of a fix to", {
        "POC": "interface, data model, auth",
        "Balanced": "data model, auth",
        "Max": "interface, data model, auth",
    }),
)  # fmt: skip
QUALITY = dict(QUALITY_ROWS)

# The guards behind those rows.
PROPOSALS: dict[Mode, tuple[ProposalMode, ...]] = {
    "POC": ("simplify",),
    "Balanced": ("simplify", "alternative"),
    "Max": ("simplify", "alternative"),
}
REFACTOR_ABOVE = 100  # Balanced's "about 100 changed lines"
RE_REVIEWS: dict[Mode, int] = {"POC": 1, "Balanced": 2, "Max": 3}
FULL_REVIEW: dict[Mode, frozenset[Area]] = {
    "POC": frozenset(AREAS),
    "Balanced": frozenset({"data-model", "auth"}),
    "Max": frozenset(AREAS),
}

# ---- Brief text (verbatim from the engineer skill and its references) ----------

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


def r0_text(base: str) -> str:
    return (
        "R0: the PR body describes the branch in the form `pr-description` picks, "
        f"read from `ctx diff origin/{base}`; keep any decisions made on the user's "
        "behalf, every recorded reason for an unfixed row, the research and "
        "decisions log, and `## Follow-ups`"
    )
