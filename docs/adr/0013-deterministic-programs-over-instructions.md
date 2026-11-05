# Prefer deterministic programs over agent instructions

An agent that follows an instruction pays for it on every run: tokens to read
it, turns to act on it, and a chance to get it wrong. A program is cheap and
fast, gives the same output for the same input, and is written once and used
many times. So where a step is mechanical, it becomes a program the agent
calls, and the instruction shrinks to one line naming it. That is why `ctx`
exists.

## Decisions

- **A program when the step is well defined.** Reading a diff, slicing it
  into an index and caching it is the same work every time, so `ctx diff`
  does it, not a paragraph of `git` commands an agent retypes.
- **An instruction when a program would get in the way.** A program must not
  limit the agent's flexibility or make it run a chain of commands to get what
  one plain command gave it. Then it should not exist and stays an
  instruction.
- **Functional shape.** A `ctx` kind has one effect, `resolve` (read git, the
  store or the network), and a pure `build`, a function of its key, memoized in
  the store. Same key, same output; nothing else is written.
- **Claims are measured first.** A program is built only when the session data
  shows a net saving over its complexity and risk.

## Evidence

- **Kept: `ctx diff`** (#319, #324). Every review pass and fixer read the same
  diff; one cached, indexed diff replaced their separate reads.
- **Rejected on measured data:** `ctx orient` (Refs #321), `ctx checks`
  (Refs #322) and `ctx ci` (Refs #323). Each measured about $5-15 per 30 days,
  under 1% of an `/engineer` run, below the cost of another kind to keep.
- **Worked example of the limit.** Agents re-read the root `CLAUDE.md` 325
  times in 30 days, though it is already in their context. A read-guard hook
  would be deterministic, but it would block the read `Edit` needs and
  `git show origin/main:CLAUDE.md` in a stale worktree. So it is one line in
  `programs/agents/instructions/agent.md` with those two exceptions.

## Considered options

- **A program for every repeated step.** Rejected: `orient`, `checks` and
  `ci` would each add a kind to maintain for under 1% of a run.
- **Instructions only.** Rejected: agents retype the same mechanical commands
  every run and drift on them, as the diff reads did before `ctx diff`.

## Consequences

- A new `ctx` kind, hook or script states the measured cost it removes.
- `.claude/rules/agents-frontend.md` and the self-improve playbook point here,
  so a proposal from either side meets the rule.
