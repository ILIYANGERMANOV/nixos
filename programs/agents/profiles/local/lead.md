## 10x-engineer on this machine

- This machine has no `add_repo` or `PushNotification`: skip them.
- Never run `gh pr merge` and never push to `epic/*`. The user merges. Their
  message "merged #n" is merge.md's "PR merged by hand" wake.
- No epics. A task that depends on another is stacked: its base branch, in the
  brief and the fixer prompt, is its dependency's branch, and its PR targets
  that branch. It starts once the dependency has a PR, not once it merged.
- When a dependency is squash merged, its stacked PR must target the default
  branch: if GitHub did not retarget it, run `gh pr edit <n> --base <default>`.
  The rebase fixer runs `git rebase --onto origin/<default> <dependency's last
  head>` in place of `git rebase origin/<base>`.
- Once a dependency is squash merged, every PR stacked on it gets that rebase
  fixer at once, conflicting or not. Its old head comes from
  `gh pr view <dependency> --json headRefOid`.
- Done is `review`: ready, green, in the queue. Finish runs once every task is
  `review`, `merged` or `parked`, and its audit counts `review` as done.
