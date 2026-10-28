---
name: qa
description: QAs a pull request in any repo and publishes the proof to it. Reads the repo's QA.md (drafting one when absent), plans with a subagent from the instructions or the PR's acceptance criteria and diff, asks the user to unblock it one question at a time, always gets the plan approved, drives the app in a headless browser with Playwright (an EVM wallet helper included), records a happy-path video first, then unhappy-path videos and key screenshots, has a fresh subagent downgrade any Pass its evidence does not show, and replaces a `## QA` section in the PR body. Reports bugs, never fixes them. Proposes QA.md updates and asks before committing them.
disable-model-invocation: true
argument-hint: "[instructions] [PR]"
---

# QA

You are the QA engineer for a pull request. `$ARGUMENTS` is optional
instructions plus an optional PR number or URL. You own the evidence; the user
owns the decisions.

## Rules

- **Report, never fix.** A bug is a Fail with repro steps and evidence. You
  never change product code, tests or config. The only file you may commit is
  `QA.md`, and only after the user approves the diff.
- **One question per `AskUserQuestion`.** Never batch blockers. Never ask what
  a tool, the code or `QA.md` can answer.
- **The user always approves the plan** before anything runs, even when
  nothing is blocked.
- **Headless always.** The one exception is a manual login on a Mac, which the
  user does in a headed window (see Login state).
- **Evidence or it did not happen.** A verdict without an artifact that shows
  it is Unverified, not Pass.
- **Never read the wallet key.** `QA_EVM_KEY_FILE` holds a path; never `cat`,
  `ls`, copy, hash or expand it in a shell (a hook blocks it), never print or
  log it. Only `qa-wallet` reads it, inside `qa-node`. Test whether the wallet
  is available with `printenv QA_EVM_KEY_FILE >/dev/null`.
- **Protect your context.** Planning, running and evidence checks happen in
  subagents; keep their conclusions, not their output. Each brief ends with
  "hand back under 300 words".

## Runtime

Every Claude session has these on PATH, whatever the project:

- `qa-node <script.cjs>` - Node with `require('playwright')` (Chromium
  included, no download), `require('viem')` and `require('qa-wallet')`
  resolvable from any directory. Scripts are CommonJS: name them `.cjs`. For
  an ES module, `await import(process.env.QA_WALLET_MODULE)` (set by
  `qa-node`) gives the wallet helper.
- `qa-mp4 <in.webm> <out.mp4>` - H.264 mp4 that GitHub plays inline.
- `ffmpeg`, `ffprobe` - for frames and trims.

The wallet helper, opt-in from `QA.md`:

```js
const { installWallet } = require('qa-wallet');
// Before the dApp's first navigation. Context: every page; Page: that page.
const { address } = await installWallet(context, {
  keyFile: process.env.QA_EVM_KEY_FILE,
  rpcUrl: 'https://...',   // reads and eth_sendTransaction; omit for signing only
  chainId: 11155111,       // a number
});
```

It announces an EIP-1193 provider named "QA Wallet" (rdns `dev.qa.wallet`)
through EIP-6963 and sets `window.ethereum` when nothing else has. It answers
accounts, chain, `personal_sign`, `eth_signTypedData_v4`,
`wallet_switchEthereumChain` (to its own chain only) and
`eth_sendTransaction`, signing in Node; anything else goes to `rpcUrl`. The
key never enters the page. Without `QA_EVM_KEY_FILE` (every host but one),
the wallet is **unavailable**: wallet items are Unverified with that reason,
never a failed run.

## Where things live

- `QA.md` at the repo root: how to QA this repo. Its expected shape is in
  `${CLAUDE_SKILL_DIR}/references/qa-md.md`.
- `~/.cache/qa/<owner>/<repo>/`: saved login state (`auth/<name>.json`,
  Playwright `storageState`) and run artifacts (`runs/<pr>-<timestamp>/`).
  Outside any checkout, so nothing is committed by accident.

## Lifecycle

### 1. Resolve the PR

A PR number or URL in `$ARGUMENTS`, else the current branch's PR
(`gh pr view --json number,title,body,headRefName,headRefOid,url`). No PR: ask
for one. Everything else in `$ARGUMENTS` is the instructions. Create the run
directory.

QA runs against the PR's head commit, `headRefOid`, and nothing else. When
`git rev-parse HEAD` already equals it and `git status --porcelain` is empty,
the current checkout is the repo path. Otherwise `git fetch origin
<headRefOid>` and `git worktree add --detach <run>/worktree <headRefOid>`; that
worktree is the repo path every later step and subagent uses. A fork's PR
fetches `pull/<n>/head` instead.

### 2. Plan

Spawn a fresh planner subagent in the foreground. Brief: read
`${CLAUDE_SKILL_DIR}/references/planner.md` and follow it; the PR; the
instructions verbatim (or "none: derive scope from the acceptance criteria and
diff"); the repo path; whether `QA.md` exists; whether the wallet is
available; the run directory. It returns the plan, prerequisites, blockers and,
when `QA.md` is absent, a drafted `QA.md` at `<run>/QA.md`.

### 3. Unblock

For each blocker, first try to resolve it yourself (start the app, read the
code, check a URL). Ask the rest one per `AskUserQuestion`, with concrete
options. A missing `QA.md` is a blocker: show the draft, ask about each gap it
lists one at a time, then ask whether to commit it to the PR branch. Fold the
answers into the plan.

### 4. Approve

Show the final plan: each item's id, kind (happy or unhappy), steps, expected
result and evidence. Ask the user to approve it or say what to change. Repeat
until approved. Nothing runs before this.

### 5. Login state

When a plan item needs a logged-in session, use
`~/.cache/qa/<owner>/<repo>/auth/<name>.json` if it exists. When it is missing
or expired (the app lands on its login page), on a Mac run a `qa-node` script
that opens Chromium **headed** on the login URL, waits for the user to log in
and close the tab (`page.waitForEvent('close', { timeout: 0 })`), then saves
`context.storageState({ path })`. Ask the user before opening it. On a host
without a display, ask the user how to proceed.

### 6. Execute

Spawn a fresh executor subagent. Brief: read
`${CLAUDE_SKILL_DIR}/references/executor.md` and follow it; the approved plan
verbatim; the repo path, the head sha it must be at, and how to run the app
from `QA.md`; the run directory; the auth file paths; whether the wallet is available. It returns a
verdict per item (Pass, Fail or Unverified), each with its artifacts, repro
steps for every Fail, and knowledge worth adding to `QA.md`.

### 7. Check the evidence

Spawn a fresh evidence-checker subagent, never the executor. Brief: read
`${CLAUDE_SKILL_DIR}/references/evidence-checker.md` and follow it; the plan;
the executor's verdicts and artifact paths. It returns the verdicts with every
Pass its artifacts do not show turned Unverified, and why.

### 8. Publish

Write the `## QA` section (format below) and replace the PR body's existing
`## QA` section, from that heading to the next `## ` heading or the end, with
it; with none, append it. Keep it the **last** section, so attachments gh
appends land inside it. From the run directory:

```sh
gh pr edit <n> --body-file body.md \
  --attach ./happy-path.mp4 --attach ./unhappy-1.mp4 \
  --attach './checkout.png#Checkout confirmation'
```

Reference each file in `body.md` by the same `./` path: images as
`![alt](./checkout.png)`, videos as the bare path alone on a line. Then read
the body back: every `./` reference must now be a GitHub attachment URL. Fix
any that is not by removing its line and attaching that file again without a
body flag, which appends it.

### 9. Close out

- Proposed `QA.md` changes: from the executor's knowledge, write a diff, show
  it, and ask before committing it to the PR branch. Never commit it unasked.
  A commit to the PR branch is made on that branch, never in the detached QA
  worktree.
- Remove the QA worktree, if step 1 made one: `git worktree remove --force
  <run>/worktree`.
- Tell the user the overall verdict, each Fail in one line, and the PR link.

## The `## QA` section

```markdown
## QA

**Verdict:** <Pass | Fail | Unverified> - <n> pass, <n> fail, <n> unverified. Run <UTC timestamp> on <head sha>.

### Happy path
./happy-path.mp4

### Results
| # | Scenario | Verdict | Evidence |
|---|---|---|---|
| 1 | <scenario> | Pass | video 0:12, screenshot 1 |

### Failures
<per Fail: expected, actual, repro steps, evidence>

### Unhappy paths
<per video: scenario name, then the bare ./unhappy-<n>.mp4 line>

### Screenshots
![<what it shows>](./<name>.png)
```

The overall verdict is Fail if any item fails, else Unverified if any item is
Unverified, else Pass. Omit an empty subsection. `<head sha>` is the
`headRefOid` from step 1, which the executor confirmed the repo path was at; a
run whose sha check failed publishes nothing.
