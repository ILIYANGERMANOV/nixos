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
- **Light on the machine.** The host may be a medium server: one dev server,
  one browser at a time, no second Node server beside the app. Waiting on the
  user is fine; waiting on a tool is waste, so nothing sleeps, polls or waits
  out a timeout.

## Runtime

Every Claude session has these on PATH, whatever the project:

- `qa-node <script.cjs>` - Node with `require('playwright')` (Chromium
  included, no download), `require('viem')` and `require('qa-wallet')`
  resolvable from any directory. Scripts are CommonJS: name them `.cjs`. For
  an ES module, `await import(process.env.QA_WALLET_MODULE)` (set by
  `qa-node`) gives the wallet helper.
- `require('qa-kit')` - what every script shares: `connect(runDir)` attaches
  to the `qa-session` browser; `expectState(expected, { name: locator })`
  waits for the expected locator or the first error locator, whichever shows;
  `capture(context, file)` logs console, page errors and failed requests with
  credentials redacted; `VIEWPORT` is the 960x540 every page and video uses.
- `qa-session start <run> [--url <url>] [--storage-state <auth.json>]
  [--chain-id <n> [--rpc <url>] [--forward-rpc <regex>]...]` - one headless
  Chromium that outlives the scripts driving it, logged in and on the page,
  with the wallet when `--chain-id` is given. It returns once the page is
  open and writes its console, redacted, to `<run>/qa-session-console.log`.
  `qa-session stop <run>` ends it. Unrecorded: probes run here.
- `qa-mp4 <in.webm> <out.mp4>` - H.264 mp4 that GitHub plays inline. It
  trims a static lead-in (a still screen from the first 1.5 s, cut to its
  last 0.5 s, never a later one) and prints the offset: cite timestamps from
  the mp4, never the webm.
- `qa-frames <video> <t1,t2,...> <out.png>` - one contact sheet of the
  frames at those seconds, each labelled with its time. One image read
  checks a whole item.
- `timeout <s> <command>` - present on every host, macOS included.
- `ffmpeg`, `ffprobe` - anything the commands above do not cover.
- `qa-wallet address` - the QA Wallet's address, derived from the key; and
  `qa-wallet balance --rpc <url> [--erc20 <token address>]...` - its native
  and ERC-20 balances. Each engineer's wallet differs, so the address is
  never stored: derive it. Exits 1 when the wallet is unavailable.

The runtime is on PATH as a store path fixed when the session started, so a
`darwin-rebuild` that changes it reaches only sessions started after it. If
the runtime must change mid-run, ask the user to restart the session; a
rebuild alone leaves `qa-node` and `QA_WALLET_MODULE` on the old build.

The wallet helper, opt-in from `QA.md`:

```js
const { installWallet } = require('qa-wallet');
// Before the dApp's first navigation. Context: every page; Page: that page.
const { address, rejectNext, waitForReceipt } = await installWallet(context, {
  keyFile: process.env.QA_EVM_KEY_FILE,
  rpcUrl: 'https://...',   // reads and eth_sendTransaction; omit for signing only
  chainId: 11155111,       // a number
  forwardRpc: [/^https:\/\/rpc\.example\//], // optional, from QA.md
});
rejectNext('eth_sendTransaction'); // the user declines the next one
rejectNext('eth_sendTransaction', { afterMs: 2000 }); // after a 2s look
await waitForReceipt(); // the last transaction it sent, once mined
```

It announces an EIP-1193 provider named "QA Wallet" (rdns `dev.qa.wallet`)
through EIP-6963 and sets `window.ethereum` when nothing else has. It answers
accounts, chain, `personal_sign`, `eth_signTypedData_v4`,
`wallet_switchEthereumChain` (to its own chain only) and
`eth_sendTransaction`, signing in Node; anything else goes to `rpcUrl`. The
key never enters the page. Without `QA_EVM_KEY_FILE` (every host but one),
the wallet is **unavailable**: wallet items are Unverified with that reason,
never a failed run.

`rejectNext(method)` makes the next request of that method fail as a user's
decline (`{ code: 4001, message: 'User rejected the request.' }`), once; call
it mid-run, e.g. after the approval and before the swap. It takes the
requests a user approves: `eth_requestAccounts`, `wallet_requestPermissions`,
`wallet_switchEthereumChain`, `personal_sign`, `eth_sign`,
`eth_signTypedData_v4`, `eth_sendTransaction`. A decline answered at once
can leave the dApp's pending state on screen for under a frame; `afterMs`
holds it long enough to record.

`waitForReceipt(hash?, { timeout })` resolves with `{ transactionHash,
status, blockNumber }` once the transaction is mined (`status` is `success`
or `reverted`), so a script waits on the chain, not on a guessed delay.
Without a hash it is the last one the wallet sent. In a session, the same two
controls are on the object `connect` returns.

`forwardRpc` answers the dApp's own JSON-RPC POSTs to matching URLs from
`rpcUrl`, for a dApp whose default RPC refuses headless traffic. `QA.md` says
when a host needs it.

## Where things live

- `QA.md` at the repo root: how to QA this repo. Its expected shape is in
  `${CLAUDE_SKILL_DIR}/references/qa-md.md`.
- `~/.cache/qa/<owner>/<repo>/`: saved login state (`auth/<name>.json`,
  Playwright `storageState`), run artifacts (`runs/<pr>-<timestamp>/`) and
  the scripts earlier runs left working (`scripts/`: a shared `lib.cjs`
  that opens the app and reaches each flow's screens, plus one file per
  scenario). Outside any checkout, so nothing is committed by accident.

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

Then start the app in the background (`run_in_background`), now, so the
install and the first compile overlap planning and approval: the install and
start commands `QA.md` gives, in the repo path, output to `<run>/app.log`.
Cap a Node dev server's heap, e.g. `NODE_OPTIONS=--max-old-space-size=2048`
for Next. Use a preview URL instead when `QA.md` gives one. Without `QA.md`,
start it once step 3 has the answer. The background job wakes you if it
exits; otherwise check it is up (one `curl`) when you brief the executor.

When the wallet is available and `QA.md` lists the funds its flows need, run
`qa-wallet balance` with the RPC and token addresses `QA.md` gives, now,
before planning. If a balance is short, ask the user to top up the printed
address while planning and setup carry on; check again before step 6.

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
`context.storageState({ path })`. Ask the user before opening it. First
follow the login link headless as far as the identity provider's page and
screenshot it: an error there (a bad redirect URL) is a Fail to report, not
something to send the user into. On a host without a display, ask the user
how to proceed.

### 6. Execute

Spawn a fresh executor subagent. Brief: read
`${CLAUDE_SKILL_DIR}/references/executor.md` and follow it; the approved plan
verbatim; the repo path, the head sha it must be at, the URL the app is
already running at (it must not start a second one); the run directory; the
auth file paths; whether the wallet is available and its balances from step
1; the scripts directory `~/.cache/qa/<owner>/<repo>/scripts/` and an index of
it, so it reads only the files it needs - each file's name and exported
functions, from `rg -n --no-heading '^(async )?function |module\.exports|^exports\.' <scripts>`.
It returns a
verdict per item (Pass, Fail or Unverified), each with its artifacts, repro
steps for every Fail, and knowledge worth adding to `QA.md`. Brief a rerun
with the previous run's findings and tell it to start from the scripts
directory.

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
- Stop what step 1 and the executor started: `qa-session stop <run>` and the
  dev server's background job.
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
