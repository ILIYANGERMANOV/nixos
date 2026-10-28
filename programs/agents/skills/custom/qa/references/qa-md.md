# The shape of QA.md

`QA.md` lives at the repo root and tells `/qa` how to QA this repo. It holds
no secrets: credentials live in the user's saved login state or a sops
secret. Every section is optional except **Run the app**; `/qa` asks about
whatever a plan needs that `QA.md` does not say.

```markdown
# QA

## Run the app
How to get a running build of the PR: install and start commands, the URL
and port, env vars and where their values come from, seed data. Or a preview
URL pattern per PR. How to know it is ready.

## Accounts and login
Which accounts or roles exist, the login URL, and the auth state names /qa
saves under ~/.cache/qa/<owner>/<repo>/auth/ (for example `user`, `admin`).
Never passwords.

## Wallet
Only for dApps. Whether QA uses the qa-wallet helper, the chain id, the RPC
URL, the connector the app shows (injected, EIP-6963, AppKit, RainbowKit)
and how to reach the connect button. Funds the flows need.

## Test data
Fixtures, sample inputs and how to reset state between runs.

## Key flows
The flows every QA run should smoke test, whatever the PR changes.

## Quirks
Known flakiness, slow screens, stable selectors, things that look like bugs
but are not.

## Out of scope
What QA never covers here and why.
```
