---
paths:
  - "programs/playwright/**"
  - "programs/agents/skills/custom/qa/**"
---

## QA tooling (`programs/playwright`)

`base` puts `programs/playwright`'s `qa` on PATH: `qa-node` (Node resolving
`playwright` with nixpkgs' Chromium, `viem` and the `qa-wallet` helper from any
directory) and `qa-mp4` (ffmpeg). The environment lives inside `qa-node`, never
the session, so a project's own Playwright keeps its own browsers.

`qa-kit`, `qa-wallet` and the `qa-check*` scripts are strict TypeScript,
compiled to ES modules in the derivation, because Node refuses type stripping
under `node_modules`. Libraries come from `pnpm-lock.yaml` at exact versions;
`tsgo` and Biome from nixpkgs. After changing the lock file (`pnpm install
--lockfile-only` in the dev shell), update `pnpmDeps.hash` in
`programs/playwright/default.nix`. `playwright` in `package.json` is for types
only: keep it at nixpkgs' `playwright-test` version. `checks.ts-test` is the
unit layer, `checks.qa` the end-to-end one.

The wallet key arrives as a secret file's path (`QA_EVM_KEY_FILE`); every
`qa-node` script reads the variable, and `checks.qa` tests the wallet helper
headless against a generated key. The factory's Remote Control units run the
unwrapped binary, so `modules/home/factory/claude-factory.nix` installs `qa`
too.
