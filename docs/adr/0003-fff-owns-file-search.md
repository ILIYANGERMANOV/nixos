# fff owns file search; telescope owns everything else

Two picker engines run side by side in Neovim. That looks like something to
clean up, so this records why it is the intended shape and what would have to
change for consolidation to be correct.

`<leader>ff` is fff.nvim. Every other picker - grep, buffer search, code
actions, resume, the git-ignored and env-file finders - is telescope. The split
is not a migration half-finished.

## Why <leader>ff moved

`<leader>ff` was `Telescope frecency workspace=CWD`, and it showed files that no
longer existed. That is by design in the extension: `frecency/klass.lua`
validates its SQLite database only once at least `db_validate_threshold`
entries have gone stale, and that threshold defaults to `10`.

```lua
if #unlinked == 0 or (not force and #unlinked < config.db_validate_threshold) then
```

So up to nine deleted files are offered as candidates at any time. Tuning the
threshold to `1` would have fixed it, but the shape of the bug - a persistent
index consulted ahead of the filesystem - is what made the alternative
attractive.

fff resolves it structurally rather than by tuning. Its frecency store only
*scores* rows the indexer returned, so a deleted file has nothing to score, and
a background file watcher retires index entries on removal. Verified against the
pinned build rather than assumed: deleting a file and rescanning drops it from
the results.

fff also supplies, as defaults, everything else that was wanted - a large
dialog with a preview, path shortening that keeps both the top-level directory
and the filename, and dotfiles-but-not-git-ignored indexing. It carries no
`settings` block for that reason, which matters more than usual here: the nixvim
`fff` module is freeform, so a misspelled key is silently ignored rather than
failing the build.

## Why telescope was not replaced wholesale

snacks.picker would have consolidated five telescope inputs into one. It was
rejected because it replaces `vim.ui.select`, and therefore the code-action
dialog, at the same time as it replaces file search - a large behavioural change
bundled into a bug fix.

fff is additive instead. It has no `vim.ui.select` provider at all, so it cannot
take over code actions even by accident, and it has no "show git-ignored files"
mode, so `<leader>fa` has to stay on telescope regardless. The engines have no
contested responsibilities: a specialist alongside a generalist, not two
overlapping suites.

## The boundary

`programs/nvim/core/search/` splits along it. `file.nix` owns fff and the
file pickers, `grep.nix` owns content search, `default.nix` owns the telescope
engine config that belongs to neither, and `shared.nix` holds the one
`excludeDirs` list that both the `fd --exclude` flags and telescope's
`file_ignore_patterns` are derived from - previously two hand-maintained lists
that had already drifted.

Adding a file picker means adding it to `file.nix`. Anything needing
`vim.ui.select`, quickfix population from a text search, or git-ignored files
belongs on telescope.

## Consequences

Two in-picker keys differ from telescope and are left alone: fff uses `<C-s>`
for a horizontal split where telescope uses `<C-x>`, and `<Esc>` closes fff
directly. Everything else - `<C-n>`/`<C-p>`, `<CR>`, `<C-v>`, `<C-t>`,
`<C-u>`/`<C-d>`, `<Tab>`, `<C-q>` - is already identical.

fff's search box is fuzzy until the query contains a glob metacharacter, at
which point the pattern is anchored to the whole relative path and `*` crosses
`/`. `useViewModel` and `*use*ViewModel*` both find
`src/hooks/useLoginViewModel.ts`; a bare `use*ViewModel` finds nothing.

fff hardcodes dark-tuned hex colours for its git-status highlight groups, and
the `highlight default link ... GitSignsAdd` fallback it writes immediately
below them never fires, because `highlight default` will not overwrite a group
that is already defined. `file.nix` re-links those groups for real, which is
also what makes them legible on catppuccin latte.

The risk accepted: fff is young and effectively single-maintainer, and it
reintroduces a persistent index - the same class of thing that caused the
original bug, mitigated by a different mechanism. Dropping `<leader>fF` left no
telescope fallback for plain file finding; `<leader>fa` is the nearest
substitute.
