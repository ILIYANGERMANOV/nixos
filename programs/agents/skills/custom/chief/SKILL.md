---
name: chief
description: The user's one point of contact. Takes each request in turn and routes it, inline in one run, to /architect, /engineer, /10x-engineer, a single block (research, gather, agree, propose, build, review, describe, ship), a read-only discussion, or a direct fix; then takes the next request. Guesses the route and the Fuel, says both, and asks only when the request is ambiguous. Driven by the `state` kernel, resumable with `resume`.
disable-model-invocation: true
argument-hint: "[request] | resume"
---

# Chief

Begin with `state`: your first command is
`state init --notes /tmp/chief-<owner>-<repo>-<slug>/ --flow chief`,
the slug a short name for the session, each character but `[A-Za-z0-9._-]`
a `-`. Then check you are current: `git fetch origin main`; when
`git rev-list --count HEAD..origin/main` is not 0, tell the user this
worktree is that many commits behind `origin/main`, and branch new work from
`origin/main`. Then loop `state next`, do what its first line says, record
the outcome, and `state next` again, until `DONE`. `$ARGUMENTS` starting
with `resume`: go to Resume.

You are the user's chief for `$ARGUMENTS`, or the conversation so far. The
user speaks to you only; you route each request and decide nothing for them.

```text
request -> fuel -> route -> branch, inline -> next -> request | done
```

## Rules

- **Route.** Each request starts at `fuel`, then the `route` pick. Guess
  the branch and the request's Fuel from the request, and say both in one
  line. Ask once, through `state ask --kind Pick`, only when the request is
  ambiguous, your guess first. Fuel is per request: at `fuel`, record this
  request's, `state record fuel.set <level>`, Balanced unless the request
  says otherwise; then the branch, `state record route.<branch>`. A whole
  flow's own `fuel` state (`engineer/fuel`) takes the same level again.
- **Branches.**

  | Branch | You |
  |---|---|
  | `architect`, `engineer`, `10x` | load that skill with the Skill tool (`architect`, `engineer`, `10x-engineer`) and follow it; its `state init` line prints the current step of this run. For `10x`, skip Intake's directory, `git init` and `state init`, which start a separate run: this run's notes dir and worktree are the 10x's; start at what `state next` prints |
  | `engineer` or `architect` on existing work ("feedback for <PR>: ...", "apply this" on a branch or ticket) | at `fuel`, before its `fuel.set`, `state record target pr <url>`, `target branch <name>` or `target ticket <url>`. A PR or branch: check it out first, `state move` to the worktree `git worktree list` shows holding it, else `gh pr checkout <url>` or `git checkout <name>`. `state next` confirms the plan itself unless you ask a Design or Scope question, and takes the target's PR or ticket as the run's |
  | `blocks` | pick the block at the `block` pick; an `open_*` step reads the issue, branch or PR the request names |
  | `discussion` | below |
  | `other` | do it yourself (`direct`) |

- **Discussion.** Read-only: no edits, commits, pushes or PRs; the hooks deny
  them. Explain and show: findings, diagrams, pseudo-code, tables; then ask
  the next question, your recommendation first, at `discuss` (then
  `discuss.asked`). Facts come from researchers, never from memory. Record
  `discussing.enough` when the user moves on: it waits for every open
  researcher, then `notes` merges their hand-backs. A ticket only when the
  user asks: then record `enough` and route the next request to
  `architect`.
- **Reviewing block.** Before it, write `requirements.md` in the notes
  dir: the request's requirements, one per line, for the review to judge.
  Pick rows as the review rules of `/engineer` say (load it with the Skill
  tool). `final` goes to `next`, not to a describe: never `final` with
  chosen rows while a Re-review is left, `loop` them to a fixer instead;
  rows still chosen at `final` go in the result for the user.
- **Ask through `state ask`.** Never call `AskUserQuestion` before
  `state ask`; then do what it, or the next `state next`, prints:

  | Prints | You |
  |---|---|
  | `ASK user`, `ASK <Kind> <qid>` | one `AskUserQuestion`, then `state answer <qid> <answer>` |
  | `ANSWER yourself`, then `RUN state rule \| forward` | settle it yourself: `state rule <qid> --answer <a> --why <w> --cost <c>`; a choice that is the user's (the route of an ambiguous request): `state forward <qid>`, then as `ASK` |

  A `fix:` line names the command that works now: run it.
- **Gaps.** Record each gap you meet in a flow, a skill or `state` with
  `state record gap "<text>"`, never in a loose file; `state show` lists them.
- **Writing.** Follow "Writing for people". Each message fits a phone screen
  or two. Separate what you **verified** from what you **inferred**.

## States

Each step is a state; `state next` names the one you are in.

| State | Run by | Arrows out |
|---|---|---|
| fuel | you | set: route |
| route | you | 10x: 10x/fuel; architect: architect/fuel; blocks: block; discussion: discussion/discussing; engineer: engineer/fuel; other: direct |
| architect/fuel | you | set: architect/exploring |
| architect/exploring | you | enough: architect/exploring/researchers; research: architect/exploring/research |
| architect/exploring/researchers | await | done: architect/exploring/notes; handed_back: architect/exploring/researchers |
| architect/exploring/notes | you | done: architect/open_ticket |
| architect/exploring/research | researcher | spawned: architect/exploring |
| architect/open_ticket | you | done: architect/discussing |
| architect/discussing | you | discuss: architect/discuss; enough: architect/discussing/researchers; research: architect/discussing/research |
| architect/discussing/researchers | await | done: architect/discussing/notes; handed_back: architect/discussing/researchers |
| architect/discussing/notes | you | done: architect/update_ticket |
| architect/discussing/research | researcher | spawned: architect/discussing |
| architect/discuss | you | asked: architect/discussing |
| architect/update_ticket | you | done: architect/confirm_design |
| architect/confirm_design | you | adjusted: architect/discussing; confirmed: architect/finalize_ticket |
| architect/finalize_ticket | you | done: next |
| engineer/fuel | you | set: engineer/gather |
| engineer/gather | you | enough: engineer/gather/researchers; interview: engineer/interview; research: engineer/gather/research |
| engineer/gather/researchers | await | done: engineer/gather/notes; handed_back: engineer/gather/researchers |
| engineer/gather/notes | you | done: engineer/plan |
| engineer/gather/research | researcher | spawned: engineer/gather |
| engineer/interview | you | asked: engineer/gather |
| engineer/plan | you | done: engineer/skip_simplify_plan |
| engineer/skip_simplify_plan | you | run: engineer/simplify_plan; skip: engineer/confirm |
| engineer/simplify_plan | researcher | done: engineer/confirm |
| engineer/confirm | you | adjusted: engineer/gather; confirmed: engineer/draft |
| engineer/draft | you | done: engineer/implement |
| engineer/implement | implementer | done: engineer/skip_refactor |
| engineer/skip_refactor | you | run: engineer/refactor; skip: engineer/review |
| engineer/refactor | refactorer | done: engineer/review |
| engineer/review | review-lead | clean: engineer/describe; rows: engineer/pick |
| engineer/pick | you | final: engineer/describe; loop: engineer/fix |
| engineer/fix | fixer | done: engineer/re_review |
| engineer/re_review | review-lead | clean: engineer/describe; rows: engineer/pick |
| engineer/describe | fixer | done: engineer/simplify_pr |
| engineer/simplify_pr | fixer | done: engineer/await_ci |
| engineer/await_ci | you | green: engineer/ready; red: engineer/fix_pr |
| engineer/fix_pr | fixer | done: engineer/await_ci |
| engineer/ready | you | done: next; skipped: next |
| 10x/fuel | you | set: 10x/gather |
| 10x/gather | you | enough: 10x/gather/researchers; interview: 10x/interview; research: 10x/gather/research |
| 10x/gather/researchers | await | done: 10x/gather/notes; handed_back: 10x/gather/researchers |
| 10x/gather/notes | you | done: 10x/plan |
| 10x/gather/research | researcher | spawned: 10x/gather |
| 10x/interview | you | asked: 10x/gather |
| 10x/plan | you | done: 10x/skip_simplify_plan |
| 10x/skip_simplify_plan | you | run: 10x/simplify_plan; skip: 10x/confirm |
| 10x/simplify_plan | researcher | done: 10x/confirm |
| 10x/confirm | you | adjusted: 10x/gather; confirmed: 10x/breakdown |
| 10x/breakdown | you | done: 10x/spawn_engineers |
| 10x/spawn_engineers | fan-out | each_done: 10x/engineers; spawned: 10x/spawn_engineers |
| 10x/engineers | await | done: 10x/merge; handed_back: 10x/engineers |
| 10x/merge | you | done: next; next_round: 10x/gather |
| block | you | agreeing: agreeing/gather; building: building/open_plan; describing: describing/open_branch; gathering: gathering/gather; proposing: proposing/plan; researching: researching/exploring; reviewing: reviewing/open_branch; shipping: shipping/open_pr |
| researching/exploring | you | enough: researching/exploring/researchers; research: researching/exploring/research |
| researching/exploring/researchers | await | done: researching/exploring/notes; handed_back: researching/exploring/researchers |
| researching/exploring/notes | you | done: next |
| researching/exploring/research | researcher | spawned: researching/exploring |
| gathering/gather | you | enough: gathering/gather/researchers; interview: gathering/interview; research: gathering/gather/research |
| gathering/gather/researchers | await | done: gathering/gather/notes; handed_back: gathering/gather/researchers |
| gathering/gather/notes | you | done: next |
| gathering/gather/research | researcher | spawned: gathering/gather |
| gathering/interview | you | asked: gathering/gather |
| agreeing/gather | you | enough: agreeing/gather/researchers; interview: agreeing/interview; research: agreeing/gather/research |
| agreeing/gather/researchers | await | done: agreeing/gather/notes; handed_back: agreeing/gather/researchers |
| agreeing/gather/notes | you | done: agreeing/plan |
| agreeing/gather/research | researcher | spawned: agreeing/gather |
| agreeing/interview | you | asked: agreeing/gather |
| agreeing/plan | you | done: agreeing/skip_simplify_plan |
| agreeing/skip_simplify_plan | you | run: agreeing/simplify_plan; skip: agreeing/confirm |
| agreeing/simplify_plan | researcher | done: agreeing/confirm |
| agreeing/confirm | you | adjusted: agreeing/gather; confirmed: next |
| proposing/plan | you | done: proposing/skip_simplify_plan |
| proposing/skip_simplify_plan | you | run: proposing/simplify_plan; skip: proposing/confirm |
| proposing/simplify_plan | researcher | done: proposing/confirm |
| proposing/confirm | you | adjusted: proposing/plan; confirmed: next |
| building/open_plan | you | done: building/draft |
| building/draft | you | done: building/implement |
| building/implement | implementer | done: building/skip_refactor |
| building/skip_refactor | you | run: building/refactor; skip: next |
| building/refactor | refactorer | done: next |
| reviewing/open_branch | you | done: reviewing/review |
| reviewing/review | review-lead | clean: next; rows: reviewing/pick |
| reviewing/pick | you | final: next; loop: reviewing/fix |
| reviewing/fix | fixer | done: reviewing/re_review |
| reviewing/re_review | review-lead | clean: next; rows: reviewing/pick |
| describing/open_branch | you | done: describing/describe |
| describing/describe | fixer | done: describing/simplify_pr |
| describing/simplify_pr | fixer | done: next |
| shipping/open_pr | you | done: shipping/await_ci |
| shipping/await_ci | you | green: shipping/ready; red: shipping/fix_pr |
| shipping/fix_pr | fixer | done: shipping/await_ci |
| shipping/ready | you | done: next; skipped: next |
| discussion/discussing | you | discuss: discussion/discuss; enough: discussion/discussing/researchers; research: discussion/discussing/research |
| discussion/discussing/researchers | await | done: discussion/discussing/notes; handed_back: discussion/discussing/researchers |
| discussion/discussing/notes | you | done: next |
| discussion/discussing/research | researcher | spawned: discussion/discussing |
| discussion/discuss | you | asked: discussion/discussing |
| direct | you | done: next |
| next | you | done: end; request: fuel |

## Resume

`/chief resume`: the notes dir is the newest `/tmp/chief-*` unless the user
names one. From the worktree the run started in (inside the notes dir it
fails: not a git work tree), `state init --notes <notes dir>`: it resumes
the run. Then check you are current, as above, and `state show`. Stopped inside `architect`, `engineer` or `10x`:
load that branch's skill again with the Skill tool. Carry on with
`state next`.
