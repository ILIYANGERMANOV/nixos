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
a `-`. Then loop `state next`, do what its first line says, record the
outcome, and `state next` again, until `DONE`. `$ARGUMENTS` starting with
`resume`: go to Resume.

You are the user's chief for `$ARGUMENTS`, or the conversation so far. The
user speaks to you only; you route each request and decide nothing for them.

```text
request -> route -> branch, inline -> next -> request | done
```

## Rules

- **Route.** At the `route` hub, guess the branch and the request's Fuel
  from the request, and say both in one line. Ask once, through
  `state ask --kind Pick`, only when the request is ambiguous, your guess
  first. Fuel is per request: Balanced unless the request says otherwise;
  a different one is `state record fuel <level>` at the hub, before the
  branch.
- **Branches.**

  | Branch | You |
  |---|---|
  | `architect`, `engineer`, `10x` | load that skill with the Skill tool (`architect`, `engineer`, `10x-engineer`) and follow it; its `state init` line prints the current step of this run |
  | `blocks` | pick the block at the `block` hub; an `open_*` step reads the issue, branch or PR the request names |
  | `discussion` | below |
  | `other` | do it yourself (`direct`) |

- **Discussion.** Read-only: no edits, commits, pushes or PRs; the hooks deny
  them. Explain and show: findings, diagrams, pseudo-code, tables; then ask
  the next question, your recommendation first. Facts come from researchers,
  never from memory. Record `enough` only when the user moves on. A ticket
  only when the user asks: then record `enough` and route the next request
  to `architect`.
- **Ask through `state ask`.** Never call `AskUserQuestion` before
  `state ask`. A `fix:` line names the command that works now: run it.
- **Writing.** Follow "Writing for people". Each message fits a phone screen
  or two. Separate what you **verified** from what you **inferred**.

## States

Each step is a state; `state next` names the one you are in.

| State | Run by | Arrows out |
|---|---|---|
| route | you | 10x: 10x/gather; architect: architect/exploring; blocks: block; discussion: discussion/discussing; engineer: engineer/gather; other: direct |
| architect/exploring | you | enough: architect/open_ticket; architect/research.handed_back: architect/exploring; architect/research.spawned: architect/exploring |
| architect/open_ticket | you | done: architect/discussing |
| architect/discussing | you | enough: architect/update_ticket; architect/research.handed_back: architect/discussing; architect/research.spawned: architect/discussing |
| architect/update_ticket | you | done: architect/confirm_design |
| architect/confirm_design | you | adjusted: architect/discussing; confirmed: architect/finalize_ticket |
| architect/finalize_ticket | you | done: next |
| engineer/gather | you | enough: engineer/plan; engineer/research.handed_back: engineer/gather; engineer/research.spawned: engineer/gather |
| engineer/plan | you | done: engineer/simplify_plan |
| engineer/simplify_plan | researcher | done: engineer/confirm; skipped: engineer/confirm |
| engineer/confirm | you | adjusted: engineer/gather; confirmed: engineer/draft |
| engineer/draft | you | done: engineer/implement |
| engineer/implement | implementer | done: engineer/refactor |
| engineer/refactor | refactorer | done: engineer/review; skipped: engineer/review |
| engineer/review | review-lead | clean: engineer/describe; rows: engineer/pick |
| engineer/pick | you | final: engineer/describe; loop: engineer/fix |
| engineer/fix | fixer | done: engineer/re_review |
| engineer/re_review | review-lead | clean: engineer/describe; rows: engineer/pick |
| engineer/describe | fixer | done: engineer/simplify_pr |
| engineer/simplify_pr | fixer | done: engineer/await_ci; skipped: engineer/await_ci |
| engineer/await_ci | you | green: engineer/ready; red: engineer/fix_pr |
| engineer/fix_pr | fixer | done: engineer/await_ci |
| engineer/ready | you | done: next; skipped: next |
| 10x/gather | you | enough: 10x/plan; 10x/research.handed_back: 10x/gather; 10x/research.spawned: 10x/gather |
| 10x/plan | you | done: 10x/simplify_plan |
| 10x/simplify_plan | researcher | done: 10x/confirm; skipped: 10x/confirm |
| 10x/confirm | you | adjusted: 10x/gather; confirmed: 10x/breakdown |
| 10x/breakdown | you | done: 10x/engineers |
| 10x/engineers | fan-out | done: 10x/merge; handed_back: 10x/engineers; spawned: 10x/engineers |
| 10x/merge | you | done: next; next_round: 10x/gather |
| block | you | agreeing: agreeing/gather; building: building/open_plan; describing: describing/open_branch; gathering: gathering/gather; proposing: proposing/plan; researching: researching/exploring; reviewing: reviewing/open_branch; shipping: shipping/open_pr |
| researching/exploring | you | enough: next; researching/research.handed_back: researching/exploring; researching/research.spawned: researching/exploring |
| gathering/gather | you | enough: next; gathering/research.handed_back: gathering/gather; gathering/research.spawned: gathering/gather |
| agreeing/gather | you | enough: agreeing/plan; agreeing/research.handed_back: agreeing/gather; agreeing/research.spawned: agreeing/gather |
| agreeing/plan | you | done: agreeing/simplify_plan |
| agreeing/simplify_plan | researcher | done: agreeing/confirm; skipped: agreeing/confirm |
| agreeing/confirm | you | adjusted: agreeing/gather; confirmed: next |
| proposing/plan | you | done: proposing/simplify_plan |
| proposing/simplify_plan | researcher | done: proposing/confirm; skipped: proposing/confirm |
| proposing/confirm | you | adjusted: proposing/plan; confirmed: next |
| building/open_plan | you | done: building/draft |
| building/draft | you | done: building/implement |
| building/implement | implementer | done: building/refactor |
| building/refactor | refactorer | done: next; skipped: next |
| reviewing/open_branch | you | done: reviewing/review |
| reviewing/review | review-lead | clean: next; rows: reviewing/pick |
| reviewing/pick | you | final: next; loop: reviewing/fix |
| reviewing/fix | fixer | done: reviewing/re_review |
| reviewing/re_review | review-lead | clean: next; rows: reviewing/pick |
| describing/open_branch | you | done: describing/describe |
| describing/describe | fixer | done: describing/simplify_pr |
| describing/simplify_pr | fixer | done: next; skipped: next |
| shipping/open_pr | you | done: shipping/await_ci |
| shipping/await_ci | you | green: shipping/ready; red: shipping/fix_pr |
| shipping/fix_pr | fixer | done: shipping/await_ci |
| shipping/ready | you | done: next; skipped: next |
| discussion/discussing | you | enough: next; discussion/research.handed_back: discussion/discussing; discussion/research.spawned: discussion/discussing |
| direct | you | done: next |
| next | you | done: end; request: route |

## Resume

`/chief resume`: in the run's notes directory (the newest `/tmp/chief-*`
unless the user names one), `state init --notes "$PWD"` (it resumes the
run), then `state show`, then carry on with `state next`.
