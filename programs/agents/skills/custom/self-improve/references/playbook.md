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
- **Lean reviews.** One fresh subagent per review pass, fewer and cheaper
  agents, mechanical checks first; the second pass reviews only the fix diff.
  Historic passes cost 15-30M tokens; the lean one about 80k context.
- **Short hand-backs** under about 300 words, and no resuming a large agent
  after the prompt cache expired.

## Wall time

From nixos#215, where foreground Bash took 5.2h over 10 runs.

- **A check ladder** in the repository's `CLAUDE.md`: the narrowest check
  while iterating, one full check per agent at the end, none after doc-only
  edits, never build/test/lint chained in front of the full check. Redundant
  and chained checks cost about 40 min.
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

## Not fixes

- Fewer questions or prompts to the person. Waiting on the person is never a
  bottleneck, and asking is cheap and important.
- Dropping a check from CI, or skipping tests to go faster.
- A stronger machine.
- A warning that cannot be silenced without a security cost, such as making
  the agent a trusted Nix user: record it as won't-fix with the reason.
