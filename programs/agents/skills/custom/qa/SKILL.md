---
name: qa
description: QAs a pull request in any repo and publishes the proof to it. Reads the QA.md of every repo in the test, the PR's and the hosts it runs in (drafting one when absent), plans with a subagent from the instructions or the PR's acceptance criteria and diff, asks the user to unblock it one question at a time, always gets the plan approved, drives the app in a headless browser with Playwright (an EVM wallet helper included), records a happy-path video first, then unhappy-path videos and key screenshots, has a fresh subagent downgrade any Pass its evidence does not show, and replaces a `## QA` section in the PR body. Reports bugs, never fixes them. Proposes QA.md updates and asks before committing them. Use only when the user asks to QA a PR or feature, never on your own initiative, and run it in the session that can ask the user, never in a delegated subagent.
argument-hint: "[instructions] [PR]"
---

# QA

You are the QA engineer for a pull request. `$ARGUMENTS` is optional
instructions plus an optional PR number or URL. You own the evidence; the user
owns the decisions.

## Rules

- **Report, never fix.** A bug is a Fail with repro steps and evidence. You
  never change product code, tests or config. The only files you may commit
  are `QA.md` files, and only after the user approves the diff. The one
  exception is a draft host PR the user chose in step 3, which an agent writes.
- **One question per `AskUserQuestion`.** Never batch blockers. Never ask what
  a tool, the code or `QA.md` can answer.
- **The user always approves the plan** before any plan item runs, even when
  nothing is blocked. That approval goes through `AskUserQuestion`, so QA runs
  in the session that can ask, never in a delegated subagent.
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
  "hand back in about 250 words, never over 300; the rest goes in a file in
  the run directory, by path". Run QA in a fresh session: one that already
  carries other work, such as an `/engineer` run, resends it on every call.
- **Light on the machine.** The host may be a medium server: one dev server,
  one browser at a time, no second Node server beside the app. Waiting on the
  user is fine; waiting on a tool is waste, so nothing sleeps, polls or waits
  out a timeout.

## Runtime

Every Claude session has these on PATH, whatever the project:

- `qa-node <script.cjs>` - Node with `require('playwright')` (Chromium
  included, no download), `require('viem')` and `require('qa-wallet')`
  resolvable from any directory. It kills a script that runs past its default
  deadline, so none can hang; a `timeout <s>` prefix ends one sooner. Scripts
  are CommonJS: name them `.cjs`. For
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
  `qa-session stop <run>` ends it. Unrecorded: probes run here. With
  `--storage-state`, the login the app renews is written back to that file
  as scripts detach, on stop and on SIGTERM, the old one kept as `.bak`, so
  the saved login stays usable from run to run.
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

The wallet helper (`require('qa-wallet')`) is documented in
`${CLAUDE_SKILL_DIR}/references/wallet.md`. Read it, and name it in the
planner's and executor's briefs, only when `QA_EVM_KEY_FILE` is set. Without
it (every host but one) the wallet is **unavailable**: wallet items are
Unverified with that reason, never a failed run.

## Where things live

- `QA.md` at each repo's root: how to QA that repo. Its expected shape is in
  `${CLAUDE_SKILL_DIR}/references/qa-md.md`.
- `~/.cache/qa/<owner>/<repo>/`, keyed by the PR's repo: run artifacts
  (`runs/<pr>-<timestamp>/`, deleted once their proof is on the PR) and the
  scripts earlier runs left working (`scripts/<host>/`, per app they drive: a
  shared `lib.cjs` that opens the app and reaches each flow's screens, plus
  one file per scenario).
- `~/.cache/qa/<host owner>/<host repo>/auth/<name>.json`: saved login state
  (Playwright `storageState`), keyed by the app logged into, so every PR that
  runs on that host shares it.

All outside any checkout, so nothing is committed by accident.

## Lifecycle

### 0. Gate

If the user did not ask for QA, or `AskUserQuestion` is unavailable, stop and
touch nothing: no run directory, worktree, app or question. Say why in one line.
If this session already carries other work, say once that a fresh session
costs far less, with the `/qa ...` line to paste, and go on unless the user
switches.

### 1. Resolve the PR and its repos

A PR number or URL in `$ARGUMENTS`, else the current branch's PR
(`gh pr view --json number,title,body,headRefName,headRefOid,url`). No PR: ask
for one. Everything else in `$ARGUMENTS` is the instructions. Create the run
directory, and save the diff once: `gh pr diff <n> > <run>/pr.diff`. Every
brief names that path, plus the `QA.md` sections the agent needs as
`path:start-end`, so no agent re-fetches the PR or reads a whole file.

QA runs against the PR's head commit, `headRefOid`, and nothing else. When
`git rev-parse HEAD` already equals it and `git status --porcelain` is empty,
the current checkout is the repo path. Otherwise `git fetch origin
<headRefOid>` and `git worktree add --detach <run>/worktree <headRefOid>`; that
worktree is the repo path every later step and subagent uses. A fork's PR
fetches `pull/<n>/head` instead.

Build the set of repos in the test: the PR's repo, every repo the
instructions name ("in @../host"), and each host the plan runs the change in.
A `QA.md`'s `## Related repos` lists siblings (local path, GitHub slug, role):
a lookup for their paths and the default host, never a reason to add one. A
sibling missing from disk is a question to the user, never a clone. Record
each in `<run>/repos.md`: path, `owner/repo`, role (subject, host or
dependency), its `QA.md` path or none, and the commit QA runs at. Read the
`QA.md` of every repo in the set before any question or probe: how to launch
the app, log in, which steps are flaky and what worked last time, which an
earlier run already paid for. When two disagree, the repo that owns the
fact wins: the host on how to run it, log in, connect a wallet and navigate
it; the subject on what the change should look like and its own flows and
quirks. The plan names each conflict and close-out proposes the fix to the
losing `QA.md`; never resolve one silently.

Then start the app in the background (`run_in_background`), now, so the
install and the first compile overlap planning and approval: the install and
start commands the host's `QA.md` gives, in the host's path, output to
`<run>/app.log`, the job's id saved to `<run>/app.job`. Cap a Node dev
server's heap, e.g. `NODE_OPTIONS=--max-old-space-size=2048` for Next. Use a
preview URL instead when `QA.md` gives one. Without `QA.md`, start it once
step 3 has the answer. The background job wakes you if it exits; otherwise
check it is up (one `curl`) when you brief the executor.

When the wallet is available and `QA.md` lists the funds its flows need, run
`qa-wallet balance` with the RPC and token addresses `QA.md` gives, now,
before planning. If a balance is short, ask the user to top up the printed
address while planning and setup carry on; check again before step 6.

When the plan will need a session, log in now (step 5), before planning.
When the instructions name test data (a record the user names), a short
headless probe in `qa-session` resolves it to concrete URLs or ids for the
planner; the plan shows the pick, and the user confirms it at approval.

### 2. Plan

Spawn a fresh planner subagent in the foreground. Brief: read
`${CLAUDE_SKILL_DIR}/references/planner.md` and follow it; the PR; the
instructions verbatim (or "none: derive scope from the acceptance criteria and
diff"); `<run>/repos.md`, `<run>/pr.diff` and the `QA.md` sections it needs;
any conflict between them; the test data step 1 resolved; whether the wallet
is available; the run directory. It writes the plan to `<run>/plan.md` and
returns its path, blockers, the funds each spending item needs and, for each
repo in the set without a `QA.md`, a draft at `<run>/QA-<repo>.md`.

### 3. Unblock

Research before you ask, as your instructions say: plan the open questions
yourself, group them, and launch one research agent per group (start the
app, read the code, check a URL) before your first question. When the
instructions only name what to QA, the topics are yours to plan. Ask the rest
one per `AskUserQuestion`, with concrete options. A missing `QA.md`, the PR
repo's or a host's, is a blocker: show the draft, ask about each gap it lists
one at a time, then ask whether to commit it (close-out says where). Fold the
answers into `<run>/plan.md`.

Check the funds the plan names for each spending item now, not in the
executor: `qa-wallet balance` for the QA wallet, one probe of the balance
screen for the app's own. A shortfall is a blocker: ask the user to top up or
say where the token comes from.

When the user picks a draft host PR for a new API the host does not consume
yet, spawn a background agent, in parallel with login: on its own branch in a
scratch worktree of the host, it wires the API in and opens a draft PR. QA
then runs on that PR's head; record it in `<run>/repos.md`. Its from-source
install of the subject is never committed.

### 4. Approve

Show the final plan from `<run>/plan.md`: each item's id, kind (happy or unhappy), steps, expected
result and evidence. Ask the user to approve it or say what to change. Repeat
until approved, editing the file to match. No plan item runs before this, and nothing is recorded or
published: only the setup of steps 1 to 3 has run, such as the worktree, the
app, login and probes.

### 5. Login state

When a plan item needs a logged-in session and step 1 did not log in, use
`~/.cache/qa/<host owner>/<host repo>/auth/<name>.json` if it exists. When it is missing
or expired (the app lands on its login page), on a Mac run a `qa-node` script
that opens Chromium **headed** on the login URL, waits for the user to log in
and close the tab (`page.waitForEvent('close', { timeout: 0 })`), then saves
`context.storageState({ path })`. Ask the user before opening it. Any other
context on the saved login, a login check included, goes through `qa-session`
or qa-kit, which write the renewed login back. First
follow the login link headless as far as the identity provider's page and
screenshot it: an error there (a bad redirect URL) is a Fail to report, not
something to send the user into. On a host without a display, ask the user
how to proceed.

### 6. Execute

Right before each executor spawn, `gh pr view <n> --json headRefOid` must
still match step 1's. If the head moved, tell the user and ask whether to
restart from step 1.

Spawn a fresh executor subagent. Brief: read
`${CLAUDE_SKILL_DIR}/references/executor.md` and follow it; the approved plan,
`<run>/plan.md`; `<run>/repos.md` (each repo's path and the commit it must be at),
`<run>/pr.diff` and the `QA.md` sections it needs; the URL the app is
already running at (it must not start a second one); the run directory; the
auth file paths; whether the wallet is available, its balances from step 1
and, if available, `${CLAUDE_SKILL_DIR}/references/wallet.md`; the scripts
directory `~/.cache/qa/<owner>/<repo>/scripts/<host>/` and an index of it, so it reads only the files it needs - each file's name and
exported functions, from `rg -n --no-heading '^(async )?function |module\.exports|^exports\.' <scripts>`.
It writes the results to `<run>/results.md` and its proposed `QA.md` lines to
`<run>/qa-md-notes.md`, and returns a verdict per item (Pass, Fail or
Unverified) with those paths. Brief a rerun with the previous run's findings and tell it
to start from the scripts directory.

### 7. Check the evidence

Spawn a fresh evidence-checker subagent, never the executor. Brief: read
`${CLAUDE_SKILL_DIR}/references/evidence-checker.md` and follow it; the plan;
every repo's commit from `<run>/repos.md`; the executor's verdicts, the
commits it reported and `<run>/results.md`. It returns the verdicts with every
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

Attach every image and video in that one call, and reference each file in
`body.md` by the same `./` path: images as `![alt](./checkout.png)`, videos
as the bare path alone on a line. gh replaces each image's `./` reference
with its attachment URL but appends the videos at the end, leaving their
`./` lines dead. So read the body back, match each appended video URL to its
file by size (download it with `gh auth token` as the bearer, compare to the
local byte count), move it onto its `./` line under its heading, and edit
again. Read it back once more: every `./` reference must now be a GitHub
attachment URL.

A PR or issue in another repository - a draft host PR, a related change - is
referenced by its full URL, `https://github.com/<owner>/<repo>/pull/<n>`,
never `#<n>` (that resolves to this repo) or shorthand.

### 9. Close out

- Update `QA.md` after every run, so the next run starts where this one
  ended: what launched the app, how login worked, flaky steps, what worked
  and what did not, from `<run>/qa-md-notes.md` and the conflicts the plan
  named. First list the improvements and ask the user which to make and
  which not. Sort the approved ones by the repo whose code each is
  about, one diff per repo, and scan each for secrets and sensitive data
  (`qa-md.md` lists what never goes in) before showing it. Then ask with
  `AskUserQuestion` whether to commit each diff: it may hold sensitive or
  non-engineering details, or a wrong assumption about the product, that
  only the user can spot. Commit each approved diff in its repo on the
  branch already in use there: the PR branch for the subject, the draft
  host PR's branch for a host. Unsure where: ask. Never commit unasked, and
  never in the detached QA worktree.
- Stop what step 1 and the executor started: the dev server with `TaskStop`
  and the job id in `<run>/app.job`, the browser with `qa-session stop
  <run>`. Never `pkill`, `killall` or a pattern kill. Then check the app's
  port is free (`lsof -i :<port>`).
- Remove the QA worktree, if step 1 made one: `git worktree remove --force
  <run>/worktree`.
- Once step 8's edit succeeded and the body read back holds a
  `https://github.com/user-attachments/` URL for every file attached, the
  proof lives on the PR: `rm -rf <run>`. Anything else - a failed upload, a
  `./` reference left, no PR edit at all - keeps the run, and you tell the
  user its path. Never delete `auth/` or `scripts/`: a rerun needs only
  those, and the previous run's findings, which you brief it from.
- Tell the user the overall verdict, each Fail in one line, and the PR link.

## The `## QA` section

```markdown
## QA

**Verdict:** <Pass | Fail | Unverified> - <n> pass, <n> fail, <n> unverified. Run <UTC timestamp> on <head sha>, in <host owner/repo> at <sha>.

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
| Screenshot | What it shows |
|---|---|
| ![<what it shows>](./<name>.png) | <what it shows> |
```

The overall verdict is Fail if any item fails, else Unverified if any item is
Unverified, else Pass. Omit an empty subsection. `<head sha>` is the
`headRefOid` from step 1, which the executor confirmed the repo path was at; a
run whose sha check failed publishes nothing. Drop the host clause when the
PR's repo is its own host.
