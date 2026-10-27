# CI security - the DEEP blockers checklist

Read by the blockers agent at DEEP depth only, after the step-1 sweep of
`blockers.md`. Run the greps at the bottom on `$D/diff` first, then walk the
checklist against every workflow, action, CI-run script and credential path the
diff touches. A hit you cannot refute is a blocker: name the attacker, the
entry point and the gain, as `blockers.md` says.

## Trigger

You are here because the orchestrator chose the **sensitive** tier, defined
in `first-pass.md` Phase 1. This checklist covers its CI and credential files;
migrations, destructive operations, ops units and firewall rules, which also
make a diff sensitive, are covered by the irreversible-damage section of
`blockers.md`.

## Checklist

The attacker is a fork PR author unless stated; the gain is in brackets.

### Triggers

- `pull_request_target` or `workflow_run` checks out `head.sha`, `head.ref` or
  `github.head_ref`, then runs repo content - install, build, `nix build`,
  `nix run` [secrets, write token, cache write]. Verify what in that tree runs:
  hooks, wrappers, `flake.nix`.
- `issue_comment` commands and label gates: the attacker pushes after approval
  (TOCTOU). Require the approved `head.sha` and gate on the PR's
  `author_association`; `github.actor == 'dependabot[bot]'` and usernames are
  spoofable.
- A deploy or release job reachable from `pull_request_target`,
  `issue_comment`, or `workflow_run` of a `pull_request` workflow, which runs
  from the PR head [deploy as the attacker]. Verify `on:` plus `if:` on
  `github.event_name` or `head.repo.fork`.

### Injection

- `${{ }}` of untrusted context in `run:`, a `github-script` `script:`, or a
  `with:` the action re-templates [RCE on the runner]. Untrusted:
  `event.{issue,pull_request}.{title,body}`, `comment.body`,
  `commits.*.message`, `head_commit.*`, `*.author.{name,email}`,
  `pull_request.head.{ref,label}`, `github.head_ref`, `inputs.*`, and step
  `outputs` derived from them. Correct form: `env:` plus `"$VAR"` or
  `process.env`.
- A step handling PR content, artifacts or cache writes `$GITHUB_ENV` or
  `$GITHUB_PATH` [env or PATH hijack of later steps].
  `ACTIONS_ALLOW_UNSECURE_COMMANDS`, `::set-env` and `::set-output` reopen the
  same hole.

### Permissions and tokens

- No top-level `permissions:`, `write-all`, or `contents`, `pull-requests`,
  `packages`, `actions` or `id-token: write` on a job touching untrusted input
  [push, approve PRs, publish, mint cloud credentials]. Expect top-level
  `contents: read` with job-level raises.
- A new PAT or all-repo app token [every repo the token reaches]; a PAT in a
  fork-reachable job started the 2025 tj-actions cascade.
- `actions/checkout` without `persist-credentials: false` before an artifact
  upload or a third-party step [token read from `.git/config`].
- `id-token: write` added, or an OIDC `sub` condition widened to
  `repo:org/repo:*` [any branch assumes the cloud role]. Expect
  `ref:refs/heads/main` or `environment:<name>`, and verify the cloud-side
  policy.
- A deploy job lost its `environment:`, or targets one without reviewers or a
  branch policy [approval gate bypassed].

### Secrets

- A secret at workflow or job `env:` (every action sees it) or in a step a PR
  influences; `toJSON(secrets)`; `fromJSON(secrets.X).field` (sub-fields are
  unmasked); a secret in CLI args, an artifact or the cache; `set -x`,
  `ACTIONS_STEP_DEBUG` or `ACTIONS_RUNNER_DEBUG`; a derived value without
  `::add-mask::` [leak to public logs, as the tj-actions payload did].
- `secrets: inherit`, or secrets handed to a new third-party action or a
  cross-repo `workflow_dispatch` [the callee holds them]. Read the callee at
  its pinned SHA.
- `docker login`, a cachix `authToken` or `signingKey`, or an attic or FlakeHub
  push token in a job on `pull_request_target`, `workflow_run` or
  `issue_comment` [push poisoned images or store paths]. A fork `pull_request`
  gets no secrets; these triggers do.

### Supply chain

- `uses:` not pinned to a 40-hex SHA; a SHA absent from the named repo (an
  impostor commit: `gh api repos/{o}/{r}/commits/{sha}`); an unknown or
  typosquat owner; an archived action; an open advisory [the action's author
  or hijacker runs with the job's token]. On a bump, diff `action.yml` and
  `dist/` between the two SHAs.
- `curl | sh`, `pip install`, `nix profile install`, an unpinned
  `container.image` or a `version: latest` installer in a privileged job
  [mutable upstream, so RCE with secrets].
- `dependabot.yml` with `insecure-external-code-execution: allow`, no
  `cooldown`, or auto-merge of action bumps [a malicious release lands
  unreviewed].
- `continue-on-error: true` or `|| true` on a scanner, signature or provenance
  check; `if: always()` on publish [the check is silently skipped].

### Cache and artifacts

- A cache (`actions/cache`, a `setup-*` `cache:`, magic-nix-cache) restored in
  a release or publish job: the default-branch cache is shared with
  `pull_request_target`, `workflow_run` and `issue_comment` runs [a poisoned
  entry runs in the release build]. `restore-keys:` prefixes let a planted
  entry win. Expect no cache in publish jobs.
- `workflow_run` downloads an artifact (`download-artifact`, `gh run
  download`) then executes, sources, installs or unpacks it into the workspace
  [RCE with secrets]. Expect extraction to `/tmp` and validation, such as a
  numeric PR number.

### Runners and Nix

- `runs-on: self-hosted` on a public repo or a fork-reachable trigger
  [persistent runner compromise]. Require ephemeral or JIT runners.
- `nix build`, `nix run` or `nix flake check` on a PR ref: evaluation runs
  fetchers and IFD, builds run arbitrary code; `--impure`, `sandbox = false`
  or `accept-flake-config` drop the sandbox [host RCE]. Acceptable only in a
  job with no secrets, a read-only token and no cache push.
- `substituters` or `trusted-public-keys` changed in `flake.nix` or a workflow
  [the attacker's cache serves store paths]. Verify against the cache's
  published key.

## Grep, on the diff

Run all five in one turn. Each matches added lines only (`^\+`), so line
numbers stay those of `diff`. A hit from the second counts only inside `run:`
or `script:`.

```sh
rg -n '^\+.*(pull_request_target|workflow_run|issue_comment|self-hosted|secrets:\s*inherit)' "$D/diff"
rg -n '^\+.*\$\{\{[^}]*(github\.event\.(issue|pull_request|comment|review|commits|head_commit|pages)|github\.head_ref|inputs\.|steps\.[^}]*\.outputs)' "$D/diff"
rg -n '^\+.*uses:\s*\S+@' "$D/diff" | rg -v '@[0-9a-f]{40}'
rg -n '^\+.*(write-all|(id-token|contents|pull-requests|packages|actions):\s*write|toJSON\(secrets|persist-credentials:\s*true)' "$D/diff"
rg -n '^\+.*(curl[^|]*\|\s*(bash|zsh|sh)|GITHUB_(ENV|PATH)|set-(output|env)|ACTIONS_(ALLOW_UNSECURE|STEP_DEBUG|RUNNER_DEBUG)|continue-on-error:\s*true|restore-keys|download-artifact|docker login|authToken|signingKey|accept-flake-config|--impure|sandbox\s*=\s*false)' "$D/diff"
```

## Sources

- https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions
- https://securitylab.github.com/resources/github-actions-preventing-pwn-requests/
- https://securitylab.github.com/resources/github-actions-untrusted-input/
- https://securitylab.github.com/resources/github-actions-new-patterns-and-mitigations/
- https://docs.zizmor.sh/audits/
- https://github.com/ossf/scorecard/blob/main/docs/checks.md
- https://adnanthekhan.com/2024/05/06/the-monsters-in-your-build-cache-github-actions-cache-poisoning/
- https://github.blog/changelog/2026-06-26-read-only-actions-cache-for-untrusted-triggers/
- https://unit42.paloaltonetworks.com/github-actions-supply-chain-attack/
- https://wiz.io/blog/new-github-action-supply-chain-attack-reviewdog-action-setup
- https://blog.yossarian.net/2024/12/06/zizmor-ultralytics-injection
- https://www.legitsecurity.com/blog/the-ultralytics-supply-chain-attack-how-it-happened-how-to-prevent
- https://www.rwx.com/blog/why-the-tanstack-supply-chain-attack-cant-happen-on-rwx
- https://github.com/cachix/cachix-action
- https://github.com/NixOS/nix/issues/9649
- https://docs.github.com/en/actions/concepts/security/openid-connect
