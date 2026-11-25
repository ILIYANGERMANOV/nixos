# Walkthrough: one real `/engineer` run

The run `9387cd01` wrote these very docs: the task was "update the harness
docs", and it built [PR #553](https://github.com/ILIYANGERMANOV/nixos/pull/553).
This page follows it step by step, from its log.

```text
fuel            ask the user: Max
  |
gather          5 researchers, 4 questions to the user
  |
notes           merge the research into one notes file
  |
plan            write plan.md
  |
simplify        researcher
standards       researcher
align           reviewer
  |
present         show the plan
  |
confirm         ask the user: build it?
  |
draft           draft PR #553
  |
implement       5 slices, one implementer each
  |
refactor        (described from the flow)
review          (described from the flow)
describe        (described from the flow)
CI              (described from the flow)
ready           (described from the flow)
```

Each step shows up to three blocks:

- **`state next`**: the line the kernel printed. The log does not store
  it, so most are rebuilt from the events and the code
  ([What `state next` prints](RUN-LOOP.md#what-state-next-prints)).
- **What the lead did**: the agent that ran `/engineer`.
- **Log**: real events from `state dump 9387cd01`, trimmed as in
  [About the excerpts](#about-the-excerpts).

| # | Time (UTC) | Step |
|---|---|---|
| 1 | 12:24 | [Fuel](#1-fuel) |
| 2 | 12:24 | [Gather: five researchers](#2-gather-five-researchers) |
| 3 | 12:30 | [Gather: four questions](#3-gather-four-questions) |
| 4 | 12:34 | [Notes and plan](#4-notes-and-plan) |
| 5 | 12:35 | [Refine: simplify, standards, align](#5-refine-simplify-standards-align) |
| 6 | 12:45 | [Present and confirm](#6-present-and-confirm) |
| 7 | 12:49 | [Draft](#7-draft) |
| 8 | 12:49 | [Implement: five slices](#8-implement-five-slices) |
| 9 | later | [Refactor](#9-refactor) |
| 10 | later | [Review](#10-review) |
| 11 | later | [Describe](#11-describe) |
| 12 | later | [CI and ready](#12-ci-and-ready) |

## 1 Fuel

```text
state next:  RUN state record fuel.set <low|balanced|max>
```

- The prompt named no Fuel, so the lead asked the user one `Confirm`
  question, Balanced recommended.
- The kernel forwarded it to the user at once: a lead may not answer a
  `Confirm` itself.
- The user picked Max. The lead recorded it.

```json
{"seq":1,"ts":"12:24:03","type":"started","data":{"flow":"engineer","notes":"...","principal":"user","interface":["ask_user","await","notify","hooks","background"]}}
{"seq":2,"ts":"12:24:06","type":"asked","data":{"qid":"9387cd01:1","kind":"Confirm","question":"Which Fuel for the harness docs rewrite? A) Balanced (Recommended) B) Max C) Low","step":"fuel","from":"self"}}
{"seq":3,"ts":"12:24:06","type":"forwarded","data":{"qid":"9387cd01:1","to":"user"}}
{"seq":4,"ts":"12:24:20","type":"answered","data":{"qid":"9387cd01:1","reply":"chose","answer":"B) Max","by":"user"}}
{"seq":5,"ts":"12:24:20","type":"fuel.set","data":{"level":"max"}}
```

Read: [GUARDRAILS: Fuel and caps](GUARDRAILS.md#fuel-and-caps),
[FLOWS: engineer](FLOWS.md#engineer).

## 2 Gather: five researchers

```text
state next:  RUN one option below      (picked: state record gather.research)
state next:  SPAWN researcher background: yes
```

- Five times, the lead recorded `gather.research` and spawned a researcher.
- The lead wrote no spawn or hand-back line. The hooks did: their ids
  start with `h:`.
- One researcher handed back `NEEDS_DECISION`: should the ADRs be merged?

```json
{"seq":6,"ts":"12:24:32","type":"gather.research","data":{}}
{"seq":7,"ts":"12:24:43","type":"gather/research.spawned","data":{}}
{"seq":8,"ts":"12:24:43","type":"worker_spawned","data":{"role":"researcher","agent":"..."}}
{"seq":21,"ts":"12:27:50","type":"gather/research.handed_back","data":{}}
{"seq":22,"ts":"12:27:50","type":"worker_returned","data":{"role":"researcher","agent":"..."}}
{"seq":26,"ts":"12:28:46","type":"worker_handed_back","data":{"role":"researcher","line":"NEEDS_DECISION should ADRs 0011-0022 be merged into fewer files? ..."}}
```

`state show` lists the hooks that write these lines, and what to do when
one misses:

```text
hooks:
  gather/research.spawned: the spawn hook, as the lead spawns a researcher
  gather/research.handed_back: the handback hook, at its hand-back
  best effort: with no recorded line after a spawn or hand-back, run state record <step>.spawned or state handback <role>
```

Read: [GUARDRAILS: hooks](GUARDRAILS.md#hooks),
[FLOWS: who runs each state](FLOWS.md#who-runs-each-state).

## 3 Gather: four questions

```text
state next:  RUN state ask --kind <kind> --from researcher <question> - triage: NEEDS_DECISION should ADRs ...
state next:  ASK Scope 9387cd01:2: How should the harness ADRs (0011-0022) be consolidated? ... - notify the user, then write the question as your final text, with no tool call after it; then state answer 9387cd01:2 <answer>
```

- The researcher's question became the run's question `9387cd01:2`, kind
  `Scope`, from the researcher. The lead ran `state forward`: a `Scope`
  question is the user's.
- The lead asked two `Scope` questions of its own: the VISION non-goals,
  and the source of this page. The kernel forwarded each to the user.
- Each answer is an `answered` event, written by `state answer`.

```json
{"seq":32,"ts":"12:30:53","type":"asked","data":{"qid":"9387cd01:2","kind":"Scope","question":"How should the harness ADRs (0011-0022) be consolidated? A) Merge ... (Recommended) B) ... C) ...","step":"gather","from":{"role":"researcher"}}
{"seq":33,"ts":"12:30:56","type":"forwarded","data":{"qid":"9387cd01:2","to":"user"}}
{"seq":34,"ts":"12:31:47","type":"answered","data":{"qid":"9387cd01:2","reply":"chose","answer":"A) Merge into a few current ADRs, delete absorbed files, fix links","by":"user"}}
{"seq":38,"ts":"12:33:30","type":"asked","data":{"qid":"9387cd01:4","kind":"Scope","question":"WALKTHROUGH.md replays a real /chief run. ... A) Rewrite it from this very /engineer run's log ...","step":"gather","from":"self"}}
{"seq":40,"ts":"12:34:21","type":"answered","data":{"qid":"9387cd01:4","reply":"chose","answer":"A) Rewrite from this /engineer run's log","by":"user"}}
```

One record was refused. `state ask` does not move the run to `interview`,
so `interview.asked` had no arrow out of `gather`. The refusal names the
commands that work; the lead ran one of them. A refusal never moves the
run.

```json
{"seq":41,"ts":"12:34:21","type":"refused","data":{"message":"interview.asked - no such arrow out of gather","fix":"state record gather.enough | state record gather.interview | state record gather.research"}}
{"seq":42,"ts":"12:34:24","type":"gather.enough","data":{}}
```

Read: [GUARDRAILS: who answers which question](GUARDRAILS.md#who-answers-which-question),
[CATEGORY-THEORY: who answers](CATEGORY-THEORY.md#ifc-who-answers),
[RUN-LOOP: the loop](RUN-LOOP.md#the-loop).

## 4 Notes and plan

```text
state next:  RUN state record plan.done <path>
```

- Every researcher had handed back, so `gather.enough` passed the wait at
  `gather/researchers` at once.
- The lead merged the five research notes into one `notes.md`, then wrote
  `plan.md`: goals, decisions, five slices, tests, acceptance criteria.

```json
{"seq":43,"ts":"12:34:48","type":"gather/notes.done","data":{}}
{"seq":44,"ts":"12:35:18","type":"plan.done","data":{"path":".../plan.md"}}
```

Read: [FLOWS: engineer](FLOWS.md#engineer).

## 5 Refine: simplify, standards, align

```text
state next:  SPAWN researcher background: yes     (simplify_plan, then standards_plan)
state next:  SPAWN reviewer background: yes       (align_plan)
```

- At Max the refine block always runs. The kernel took `skip_refine.run`
  itself, half a second after `plan.done`.
- Two researchers and one reviewer each read the plan once. The hand-back
  hook recorded each `*.done`.
- Each time the lead also recorded the same `*.done`. The run had moved on
  already, so the kernel refused it. Nothing changed: the hook's line
  stands.

```json
{"seq":45,"ts":"12:35:18","type":"skip_refine.run","data":{}}
{"seq":47,"ts":"12:36:33","type":"simplify_plan.done","data":{}}
{"seq":49,"ts":"12:36:58","type":"refused","data":{"message":"simplify_plan.done - no such arrow out of standards_plan","fix":"state record standards_plan.done"}}
{"seq":54,"ts":"12:42:47","type":"worker_spawned","data":{"role":"reviewer","agent":"..."}}
{"seq":55,"ts":"12:44:36","type":"align_plan.done","data":{}}
```

Read: [FLOWS: where Fuel skips a step](FLOWS.md#where-fuel-skips-a-step),
[RUN-LOOP: the run store](RUN-LOOP.md#the-run-store) (a hook record is
written once).

## 6 Present and confirm

```text
state next:  RUN state record present.done
state next:  ASK Confirm 9387cd01:5: Build this plan? A) Yes, build it B) No, adjust - notify the user, then write the question as your final text, ...
```

- The lead wrote `present.md`: what and why, decisions, a flow sketch.
- It asked the user to confirm. `No, adjust` would have gone back to
  `gather`.

```json
{"seq":58,"ts":"12:45:18","type":"present.done","data":{}}
{"seq":59,"ts":"12:45:20","type":"asked","data":{"qid":"9387cd01:5","kind":"Confirm","question":"Build this plan? A) Yes, build it B) No, adjust","step":"confirm","from":"self"}}
{"seq":61,"ts":"12:49:04","type":"answered","data":{"qid":"9387cd01:5","reply":"chose","answer":"A) Yes, build it","by":"user"}}
{"seq":62,"ts":"12:49:04","type":"confirm.confirmed","data":{}}
```

Read: [GUARDRAILS: who answers which question](GUARDRAILS.md#who-answers-which-question).

## 7 Draft

```text
state next:  RUN state record draft.done <url>
```

- The lead pushed the plan as one commit and opened draft PR #553.
- From here each event carries the new `HEAD`; the envelope's `head`
  field moves from the base to `8884efec`.

```json
{"seq":63,"ts":"12:49:22","type":"draft.done","data":{"url":"https://github.com/ILIYANGERMANOV/nixos/pull/553","base":"main","branch":"harness-docs"}}
```

Read: [RUN-LOOP: the run store](RUN-LOOP.md#the-run-store).

## 8 Implement: five slices

`state next` at this step, as printed during slice 5:

```text
SPAWN implementer background: yes
  at implement: a step an implementer subagent runs - spawn it with the task below; its hand-back is recorded by the hook, ...
  outcomes:
    implement.done - on to skip_refactor
  fuel: max
  changed lines: 3843
  PR: https://github.com/ILIYANGERMANOV/nixos/pull/553 (draft)
```

- The plan has five slices, one implementer each, one after another.
- The flow has one `implement` state, and its one outcome is
  `implement.done`. So the hook recorded `implement.done` at the first
  implementer's hand-back, and the run moved on. At Max the kernel then
  took `skip_refactor.run`.
- The lead went back with `state override implement "<why>"`. An override
  is the escape hatch: it moves the run by hand, and the log keeps the
  why. It did this after each of slices 1 to 4.

```json
{"seq":64,"ts":"12:49:48","type":"worker_spawned","data":{"role":"implementer","agent":"..."}}
{"seq":65,"ts":"12:59:21","type":"implement.done","data":{"head":"2ad016fd...","touches":["interface","data-model","auth"]}}
{"seq":67,"ts":"12:59:23","type":"skip_refactor.run","data":{}}
{"seq":68,"ts":"12:59:26","type":"overridden","data":{"to":"implement","why":"slice 1 of 5 done; slices 2-5 remain"}}
{"seq":83,"ts":"13:18:07","type":"overridden","data":{"to":"implement","why":"slice 4 of 5 done; slice 5 remains"}}
```

**Binding.** Each agent is bound to its run and that run's worktree. The
`state-route` hook denies a `state` call aimed at another worktree. The lead
once ran `state record` from outside the worktree, and the hook denied it.
A denied call never reaches the kernel, so the log holds no line for it.
The denial reads in this form ([`Route.hs`](../../programs/agents/kernel/src/State/Cli/Route.hs)):

```text
state record: <dir> is in no git worktree - this agent is bound to run 9387cd01 at <worktree>
fix: cd <worktree> && state record ...
```

Read: [GUARDRAILS: hooks](GUARDRAILS.md#hooks),
[VISION: non-goals](../../programs/agents/VISION.md#non-goals-draft) (the
escape hatch),
[ADR 0014](../adr/0014-pure-core-event-sourced-flow.md) (override is the
one event the graph does not decide).

## 9 Refactor

Described from the flow; this step had not run when this page was written.

- After slice 5, the run goes on to `skip_refactor`. At Max it runs.
- A `refactorer` subagent makes one refactor pass over the branch.
- Its hand-back records `refactor.done`, and the run moves to `review`.

Read: [FLOWS: where Fuel skips a step](FLOWS.md#where-fuel-skips-a-step).

## 10 Review

Described from the flow; this step had not run when this page was written.

- A `review-lead` subagent reviews the PR once.
- No rows: `review.clean` goes to `describe`.
- Rows: `review.rows` goes to `pick`. The lead picks rows to fix
  (`pick.loop`), a `fixer` fixes them, and a re-review reads only the fix.
  The exception: a fix that touches the data model or auth, or at Max an
  interface, gets a review of the whole branch.
  `pick.final` ends the loop.
- The loop is capped by the Fuel, and the stuck rule stops a loop that
  meets the same problem twice.

Read: [FLOWS: the caps](FLOWS.md#the-caps),
[GUARDRAILS: the stuck rule](GUARDRAILS.md#the-stuck-rule).

## 11 Describe

Described from the flow; this step had not run when this page was written.

- A `fixer` runs three steps: `describe` writes the PR text, `visual` adds
  its pictures, `simplify_pr` makes the text plainer.
- No Fuel skips them.

Read: [FLOWS: who runs each state](FLOWS.md#who-runs-each-state).

## 12 CI and ready

Described from the flow; this step had not run when this page was written.

- At `await_ci` the lead waits for CI: `state next` prints
  `AWAIT ci <PR>`, and the lead ends its turn until CI reports.
- Red: `await_ci.red` goes to `fix_pr`; a `fixer` fixes CI and the run
  waits again.
- Green: `await_ci.green` goes to `ready`. The lead marks the PR ready, and
  `state next` prints `DONE <url>`.

Read: [RUN-LOOP: what `state next` prints](RUN-LOOP.md#what-state-next-prints),
[GUARDRAILS: CI on top](GUARDRAILS.md#ci-on-top).

## About the excerpts

- Source: `state dump 9387cd01`, 83 events up to the start of slice 5, and
  `state show` and `state next` run in the run's worktree.
- Each event keeps its `seq`, `ts`, `type` and `data`. The envelope (`v`,
  `id`, `run`, `head`, `session`) is dropped. Times are cut to `HH:MM:SS`,
  all on 2026-11-25.
- `...` marks a cut value: notes paths, agent ids, long text, full shas.
- The `state next` lines are rebuilt from the events and the kernel's code,
  except the one in [step 8](#8-implement-five-slices), which is real.
- How a run's log is stored and replayed:
  [RUN-LOOP: replay is a fold](RUN-LOOP.md#replay-is-a-fold),
  [CATEGORY-THEORY: log](CATEGORY-THEORY.md#log-memory).
