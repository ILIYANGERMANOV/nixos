# Re-review of fixes

Earlier rounds covered the branch. This pass covers only what changed since
the previous round's head, `<prev-head>` from `--fixes`. You are the one reviewing agent: spawn
none, unless the fixes are large, then `subagent_type: reviewer`. Your budgets are the bar's
(`references/bar.md`); batch every independent command.

## 1. Write the fix diff

```sh
ctx delta <prev-head>   # the work tree; line 1 is $D, then counts and ancestor
```

For a PR, fetch `pull/<n>/head` and run `ctx delta <prev-head> FETCH_HEAD`.
The folder is the fix diff for the rest of the re-review: read it in ranges,
`index` then `sed -n`, and never run `git diff` or `gh pr diff` again. A
manifest of `0 files` ends the review: report "no changes since `<prev-head>`".

## 2. Decide the scope

The fixes are **large** when any of these holds:

- more than 300 changed lines, as the Quality table's note defines them
  (the manifest's `+A -D` added up, generated lockfiles aside);
- more than 10 files;
- the manifest says `ancestor: no`, so history was rewritten and
  the fix diff no longer isolates the fixes.

Large fixes get a full review when your row in the Quality table's Large fix
widens on names what made them large: run `references/first-pass.md` on the whole branch,
and say in one line under the assumptions why. Otherwise continue here.

## 3. Review the fix diff yourself

Read `references/bar.md` - it is your bar too - and `references/blockers.md`.
Then, over the fix diff only:

- **Requirements the fixes touch.** A requirement is touched when the fix diff
  changes a file, function or behaviour inside its scope. Recheck each touched
  one at STANDARD depth, mechanical checks first. An untouched one gets the
  verdict "unchanged - the fixes do not touch it": the latest round's verdict
  stands, and your caller holds it.
- **"Finding N is fixed: <What and Impact>"** requirements: met iff the fix
  removes that cause, checked on the code.
- **A fast blockers check**: the step 1 sweep of `blockers.md` on the fix diff,
  then any security hole or irreversible damage the fixes introduce. If the
  fix diff is in the sensitive tier, run on it the greps of
  `references/common-attacks.md` and of each reference the routing table in
  `first-pass.md` Phase 1 matches for it or a `security-sensitive`
  requirement names. Keep what you checked for the report's Security line.
  Its `<tier>` is the fix diff's, classified by `first-pass.md` Phase 1; if
  the caller names a higher tier, such as the first review's, keep that one.
- **The data-model gate**: when the fix diff adds or changes a table, column,
  field or piece of state, run Job 3 of `references/house-rules.md` over it.
- **Obvious mistakes and negligence**: the bar's always-check list, and whether
  a fix broke what it touched - its callers one hop out.

Do not review code outside the fix diff; earlier rounds did. Refute your own
findings as the bar and `blockers.md` say, then write the report.
