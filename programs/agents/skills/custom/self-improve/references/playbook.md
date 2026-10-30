# Fix playbook

Fixes that worked before, by the bottleneck they removed. Use them as
suggested options; the numbers are what each one measured at the time.

## Context and tokens

From nixos#212, where 5 `/engineer` runs cost 249M input tokens.

- **Context budget.** An agent past about 220k context commits, hands back a
  short note and stops; a fresh agent continues. One implementer had reached
  479k context and 73M tokens.
- **Mini-engineer implementers.** A large slice is planned into parts, each
  run by a fresh sub-implementer, instead of one agent growing for hours.
- **Bounded reads.** `rg -n`, then a `sed -n` range; a hook blocks multi-file
  reads over 8KB. File reads were 38% of implementer cost.
- **Same review coverage, at lower cost.** One fresh subagent per review pass,
  one shared diff file, mechanical checks first, and a second pass on the fix
  diff only. Historic passes cost 15-30M tokens; the lean one about 80k
  context. No review agent was dropped for cost: the gain was cheaper context,
  not less coverage.
- **Short hand-backs** under about 300 words, and no resuming a large agent
  after the prompt cache expired.

## Agent communication

- **Notes file, ranked hand-back.** A research agent writes its full notes to
  `/tmp/<dir>/<topic>.md` and hands back a ranked index with the path. The
  parent carries the index, and the agent that needs a section reads only that
  section. Use it when findings exceed the hand-back limit.
- **One agent explores and implements.** When exploring feeds directly into a
  change, splitting it makes the implementer re-read what the explorer read.
- **A brief that states the answer's shape**: the goal, the facts it needs and
  what to hand back, so the parent neither sends a follow-up to fix the brief
  nor spawns again for what the hand-back left out.
- **Trust a verified hand-back.** The parent keeps the conclusion and does not
  re-read the files behind it. This never covers a gate: a fix or a review
  that verifies independently stays.

## Wall time

From nixos#215, where foreground Bash took 5.2h over 10 runs.

- **A check ladder** in the repository's `CLAUDE.md`: the narrowest check
  while iterating, targeted checks only for implementers, fixers and
  refactor passes, one full check by the last agent to push and only for a
  large change, none after doc-only edits, never build/test/lint chained in
  front of the full check. Redundant and chained checks cost about 40 min.
- **Background long commands** with `run_in_background`, never a foreground
  `sleep` or `until` loop (15 min lost, 7 calls hit the timeout).
- **Missing tooling fixed at the source**: a `default` dev shell when agents
  ran `nix develop -c` without one, a package for a tool the harness claimed
  was installed. A bare push that went to the wrong branch is fixed by the
  owner in this repository's Nix config, never by an agent changing the push
  or tracking config.

## Slow builds in a repository

From deslop#251, where `nix run .#test` cost 37 min over 10 runs while the
suite itself ran in 8s.

- **Compile in parallel** (`--ghc-options=-j4` for GHC) in the build and test
  recipes: cold build 86s to 53s.
- **A warm quick-test** that runs the tests inside the already-running
  typecheck daemon: 3-7s per filtered run instead of a cabal relink.
- **Decomposed checks** so an agent can run the one it needs, documented as the
  check ladder in that repository's `CLAUDE.md`.

## Quality ROI

What the quality steps bought in one look at this factory: ten days, 94
sessions, 23 of them `/engineer`, while the loop itself was changing. A small
sample with hand-tuned step labels, and finding counts from before the
orchestrator judged them: a lead for the quality review, never a verdict.

- **The second review pass** cost about 8% of the first pass's tokens and found
  a Major in 3 of 19 runs. Two of those three read as bugs the fix itself
  added, on one unverified reading.
- **The refactor pass** took about 4% of estimated spend and finds no bugs by
  design: its value is maintainability. Its cost outliers are the target, not
  its existence.
- **The standard blockers agent** found nothing in 33 runs. It is insurance,
  the gate a naive analysis would cut; the deeper variant found 3 Majors in 11.
- **The tests agent** was the cheapest source of Majors among the standard
  agents, mostly tests that could never fail.
- **Running the thing beats reading it**, on a sample of 3: one stress test
  found 2 bugs on a branch with clean reviews, and the two bugs the user found
  were runtime failures that passed two reviews and CI.
- **A review class that recurs wants a lint or hook**: it saves review tokens
  and raises quality, so it is the top of the win-win list.

Outside evidence is indirect: no study isolates repeated self-review by one
agent. Each claim below was checked at its primary source or abstract page.

- Failed checks are the strongest predictor of an agent PR not merging, each
  cutting merge odds about 15% (arXiv 2601.15195), so CI stays green first.
- Maintainers would not merge roughly half of 296 test-passing AI PRs (METR
  note, March 2026), so a quality pass beyond tests targets a real class.
- Cursor adoption brought a temporary velocity rise and a lasting rise in
  warnings and complexity, which a panel analysis names as major drivers of the
  later velocity decline (He et al., arXiv 2511.04427), so speed bought with
  quality may not last.
- Repository context files raised cost over 20% with no general success gain
  (arXiv 2602.11988), so instructions earn their place by departing from
  default behaviour.
- Reviewer framing biases LLM reviewers (arXiv 2603.18740): give a reviewer the
  code and the intent, never the verdict.

Measure from transcripts, never from self-report. METR's 2025 "19% slower"
result is marked out of date by METR: do not cite it as current.

## Not fixes

- Fewer questions or prompts to the person. Waiting on the person is never a
  bottleneck, and asking is cheap and important.
- Dropping a check from CI, or skipping tests to go faster.
- Removing or merging a refactor, review, fix or QA pass because it is
  expensive. Make it cheaper instead.
- A stronger machine.
- A warning that cannot be silenced without a security cost, such as making
  the agent a trusted Nix user: record it as won't-fix with the reason.
