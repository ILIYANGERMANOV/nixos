# Hand over

Read this only once the action picker is answered with something to do.
Selecting no action means nothing: the review is done.

## The actions

- **Fix + commit & push** - edit the files, commit, and push the branch under
  review.
- **Fix locally** - edit the files only. Never `git add`, `git commit` or
  `git push`.
- **Post to PR** - post the review, under the rules below. Offered only when
  there is a PR: the PR argument, or an open PR for the current branch
  (`gh pr view`).

Several combine: fix, commit and push, then post a comment summarising what was
found and fixed, naming the commit. The two fix options are exclusive; if both
are picked, **Fix + commit & push** wins.

Fix only the findings that were kept. Fixes land on the branch under review:
for a PR that is not checked out, `gh pr checkout <n>` first. Push as an
ordinary push - never force-push, never push `main`. Run the repo's own checks
for what you changed before committing, and say if one fails rather than
pushing over it.

A clean review can only be posted, as a single `gh pr comment` saying nothing
serious was found.

## Posting

One review with inline comments anchored to `file:line`, plus a short summary
body. If a comment cannot be anchored - the line is not in the diff - fall back
to a single `gh pr comment` carrying the table.

**Disclose the AI review.** The summary body, or the fallback comment, opens with
one of these lines, verbatim, once - never on the inline comments:

- With findings: `🤖 AI-assisted review. I read every finding below and accepted it before posting.`
- Clean: `🤖 AI-assisted review. I read it and accepted it before posting.`
- When another agent answered the pickers, no human accepted anything:
  `🤖 AI review, posted by an agent. No human has read it yet.`

The sentence is a claim about the user, theirs to make. Post it as written, with
no hedging about what the model did or did not check.

**The event type.** Never `APPROVE`: approving is a human's sign-off.
`COMMENT` is the default, and the only choice when no Major survived unfixed.
`REQUEST_CHANGES` fits when a Major survived and is still unfixed - recommend it
and ask; it is the user's call.

```sh
gh api "repos/{owner}/{repo}/pulls/{n}/reviews" \
  -f event=COMMENT -f body='<disclosure + summary>' \
  -F 'comments[][path]=src/auth.ts' -F 'comments[][line]=41' \
  -F 'comments[][body]=<finding>'
```
