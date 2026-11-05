# Fix playbook

Levers that worked on this machine, by the bottleneck they removed, with what
each measured at the time. Suggested options, not verdicts.

## Context and tokens (nixos#212: 5 `/engineer` runs, 249M input tokens)

- **Context budget**: past about 220k an agent commits, hands back a note and
  stops; a fresh one continues. One implementer had reached 479k and 73M.
- **Leaf implementers**: the engineer slices a large task up front and spawns
  each implementer; an implementer spawns none and hands back at the 150k
  warning. Implementers that spawned children waited past the cache: 29
  rewrites, $12 in 30 days (nixos#325).
- **Bounded reads**: `rg -n`, then a `sed -n` range; a hook blocks reads over
  16KB. File reads were 38% of implementer cost.
- **Lean review passes**: one fresh subagent per pass, one shared diff file,
  mechanical checks first, pass 2 on the fix diff only. Old passes cost
  15-30M; the lean one about 80k context. Pass 2 on the fix diff alone is
  narrower coverage: offer it as a quality risk.
- **Short hand-backs** under about 300 words; no resuming a large agent after
  its cache expired.

## Agent communication

- **Notes file, ranked hand-back**: the agent writes full notes to a file and
  hands back an index with the path; whoever needs a section reads only it.
- **One agent explores and implements** when exploring feeds the change, so
  the implementer does not re-read what an explorer read.
- **A brief that states the answer's shape**: the goal, the facts, what to
  hand back, so the parent sends no follow-up and spawns no second agent.
- **Trust a verified hand-back**: keep the conclusion, do not re-read its
  files. Never for a gate: an independent fix or review stays.
- **A program over an instruction** for a mechanical step, built only when
  measured data shows a net saving: nixos
  `docs/adr/0013-deterministic-programs-over-instructions.md`.

## Wall time (nixos#215: foreground Bash 5.2h over 10 runs)

- **A check ladder** in the repository's `CLAUDE.md`: narrowest check while
  iterating, targeted checks for implementers, fixers and refactor passes,
  one full check at the end, none after doc-only edits, nothing chained in
  front of it. Redundant and chained checks cost about 40 min.
- **Background long commands** with `run_in_background`, never a foreground
  `sleep` or `until` loop (15 min lost, 7 calls timed out).
- **Missing tooling fixed at the source**: a `default` dev shell, a package
  for a tool the harness claimed. A bare push to the wrong branch is fixed in
  this repository's Nix config, never by an agent changing push config.

## Slow builds (deslop#251: `nix run .#test` 37 min over 10 runs, suite 8s)

- **Parallel compile** (`--ghc-options=-j4`): cold build 86s to 53s.
- **A warm quick-test** inside the running typecheck daemon: 3-7s per run
  instead of a cabal relink.
- **Decomposed checks**, documented as that repository's check ladder.

## Quality ROI (10 days, 94 sessions, small sample: leads only)

- **Review pass 2** cost about 8% of pass 1 and found a Major in 3 of 19 runs.
- **Refactor** took about 4% of spend and finds no bugs by design; its cost
  outliers are the target, not its existence.
- **The blockers agent** found nothing in 33 runs: insurance, the gate a
  naive analysis cuts. The DEEP variant found 3 Majors in 11.
- **The tests agent** was the cheapest source of Majors, mostly tests that
  could never fail.
- **Running the thing beats reading it** (n = 3): a stress test found 2 bugs
  behind clean reviews; the user's 2 bugs were runtime failures past CI.
- **A recurring review class wants a lint or hook**: fewer review tokens and
  more quality, the top of the win-win list.
- Outside: failed checks cut an agent PR's merge odds about 15% each (arXiv
  2601.15195); maintainers would not merge about half of test-passing AI PRs
  (METR, March 2026); context files raised cost over 20% with no general gain
  (arXiv 2602.11988); a reviewer given the verdict is biased (arXiv
  2603.18740). METR's 2025 "19% slower" is out of date.

## Not fixes

- Dropping a CI check, skipping tests, or removing a refactor, review, fix or
  QA pass for its cost: make it cheaper. A stronger machine.
- A warning that only a security cost silences, such as a trusted Nix user:
  won't-fix, with the reason.
