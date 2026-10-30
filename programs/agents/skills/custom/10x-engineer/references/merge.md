# Merge loop

One merge at a time. A wake only says where to look: re-read everything live.

## Read

```sh
gh pr view <n> --repo <owner>/<repo> \
  --json state,isDraft,baseRefName,headRefOid,mergeable,reviews
gh pr checks <n> --repo <owner>/<repo>
gh api repos/<owner>/<repo>/compare/<base>...<headRefOid> --jq .behind_by
gh api 'repos/<owner>/<repo>/commits/HEAD/check-runs?per_page=100' \
  --jq '[.total_count, ([.check_runs[] | select(.conclusion == "failure" or .conclusion == "timed_out")] | length)]'
```

`gh pr checks` exits 0 when green and 8 while pending. Read the SHA first, so a
later push fails the merge instead of slipping past the check. The last command
gives `[all, failed]` checks on the default branch's head. `all` at 0 means CI
does not run on push, so the base is unknown: section 7 says how to treat it.

## Gates

Every one must hold for the SHA you read. Rulesets enforce the approval count
only: they do not require CI, and they keep an approval across later pushes.

| Gate | Holds when | Otherwise |
|---|---|---|
| Open | `state` is `OPEN`, `isDraft` false | Merged or closed: Wakes. Draft: open a decision |
| Approved | the user's latest non-`COMMENTED` review is `APPROVED`, on this SHA or on one the ledger's merge-safe heads chain to it | Ask for approval |
| Green | `gh pr checks` exits 0 with at least one check, or the PR has no check and the user's recorded answer accepts that | State `ci`, section 7 |
| Base | `failed` is 0, or this PR is the base fix | Section 7's base path, as for a red PR, then take the next PR |
| Current | `behind_by` is 0 and `mergeable` is not `CONFLICTING` | Rebase |

Only the user's review counts, read from `reviews`, never a comment. A CI fix or
any other push after approval needs a new approval. An epic child skips the
Approved gate; a PR to `main` never does.

## Merge

```sh
gh pr merge <n> --repo <owner>/<repo> --squash --match-head-commit <sha>
```

`mergeable` may read `UNKNOWN`: read it once more before acting. Still
`UNKNOWN`: merge anyway, GitHub refuses a conflict. A refused merge: read again
from the top. Refused twice: open a decision.

## Rebase

Through a fresh fixer in the task's worktree, in `references/brief.md`'s form,
given the live `headRefOid` and counted against both caps. On its hand-back,
with `<new head>` read live, compare yourself:

```sh
git -C <worktree> fetch origin <base> <branch>
git -C <worktree> range-diff origin/<base>..<old head> origin/<base>..<new head>
git -C <worktree> rev-list --merges origin/<base>..<new head>
```

- Every range-diff line `=` and no merge commit, which range-diff skips: clean.
  Add `<old head> -> <new head>` to the merge-safe heads. Approved then passes
  without a new approval only if the chain reaches an approved commit.
- Anything else: code changed, so no chain. The Approved gate asks for a new
  approval: say what changed. An epic child needs none.

Either way, state `ci` and section 7 from step 1, whose end reruns the gates.

## After each merge

GitHub sends no webhook when a base advance makes a PR conflict, so check it
yourself:

1. Confirm `state` is `MERGED`. Mark the task `merged`, notify.
2. `git -C <clone> worktree remove <path>`, then
   `git -C <clone> branch -D <branch>`, with `<clone>` as `references/brief.md`
   defines it.
3. After a base fix, merge the default branch into each live epic of that repo,
   never a rebase, since children branch from it:
   `gh api repos/<owner>/<repo>/merges -f base=epic/<name> -f head=<default>`.
   A 409 is a conflict: escalate it. An epic whose final PR is `running` is
   skipped: the Current gate catches it.
4. Read `mergeable` for each other open PR of a live task in that repo. A
   `CONFLICTING` PR gets a rebase, and after a base fix so does each PR red on
   the base: in a slot free under both caps, else `queued`. A `running` task is
   skipped: the Current gate catches it. One merely behind rebases when its turn
   comes, so CI does not run for nothing.
5. Dispatch what the merge unblocked, then take the next approved PR.

## Wakes

- `APPROVED`: this loop for a `review` task. From `ci` or `qa`, section 7 gets
  here.
- `CHANGES_REQUESTED` or a comment from the user: triage it like a hand-back.
  What it needs goes to a fresh fixer, then `ci`, then a new approval.
- PR merged by hand: After each merge. Closed unmerged: `parked closed unmerged`,
  notify.
