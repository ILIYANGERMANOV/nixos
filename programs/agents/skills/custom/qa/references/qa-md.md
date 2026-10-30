# The shape of QA.md

`QA.md` lives at the repo root and tells `/qa` how to QA this repo. It holds
static facts only: no environment data such as specific records, ids or
account state (a how-to note that names no record is fine, such as which
label a card shows and how to match it); no secrets, credentials, account ids, wallet addresses or
internal URLs, since a repo may be public. Describe how to find data
instead. Credentials live in the user's saved login state or a sops secret.
Every section is optional except **Run the app**; `/qa` asks about whatever a
plan needs that `QA.md` does not say.

```markdown
# QA

## Run the app
How to get a running build of the PR: install and start commands, the URL
and port, env vars and where their values come from, seed data. Or a preview
URL pattern per PR. How to know it is ready. The app as a user reaches it,
never Storybook or a component preview. A memory cap the dev server runs
under, e.g. `NODE_OPTIONS=--max-old-space-size=2048` for Next.

## Accounts and login
Which accounts or roles exist, the login URL, and the auth state names /qa
saves under ~/.cache/qa/<owner>/<repo>/auth/ for this app (for example
`user`, `admin`). Never passwords.

## Wallet
Only for dApps. Whether QA uses the qa-wallet helper, the chain id, the RPC
URL, any `forwardRpc` patterns the host needs headless, the connector the
app shows (injected, EIP-6963, AppKit, RainbowKit) and how to reach the
connect button. Funds each flow needs, as token addresses `qa-wallet balance`
can check, which wallet pays (the QA wallet or the app's own), and how to get
testnet funds. Never a wallet address: each engineer's differs.

## Test data
Fixtures, sample inputs, how to find a record a flow needs, and how to reset
state between runs.

## Key flows
The flows every QA run should smoke test, whatever the PR changes, how to
find the test data that works for each, and the framing a recording needs.

## Related repos
Siblings a QA run may involve, one line each: local path (relative to this
repo), GitHub `owner/repo`, and role (the host that runs this repo's
changes, a dependency). /qa uses it to find paths and the default host; it
never adds a repo to a run by itself.

## Quirks
Known flakiness, slow screens, stable selectors, things that look like bugs
but are not, and what worked when an obvious approach did not.

## Out of scope
What QA never covers here and why.
```
