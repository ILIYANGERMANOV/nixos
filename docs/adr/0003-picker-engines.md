# Three picker engines, split by what they search

Three fuzzy-picker engines run side by side in Neovim. That looks like
something to clean up, so this records why it is the intended shape, which
engine owns what, and what would have to change for consolidation to be
correct.

- **fff** owns file search: `<leader>ff`.
- **snacks.picker** owns content search: `<leader>fd`, `<leader>fg`,
  `<leader>fw`, `<leader>ss`, and the `<leader>fl` resume that goes with them.
- **telescope** owns everything else: the git-ignored and env-file finders,
  recent files, the LSP pickers, neoclip, and the `vim.ui.select` provider
  behind every code-action dialog.

None of this is a migration half-finished. Each boundary was drawn for a
reason, and the reasons are different.

## Why `<leader>ff` moved to fff

`<leader>ff` was `Telescope frecency workspace=CWD`, and it showed files that
no longer existed. That is by design in the extension:
`frecency/klass.lua` validates its SQLite database only once at least
`db_validate_threshold` entries have gone stale, and that threshold defaults
to `10`.

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
and the filename, and dotfiles-but-not-git-ignored indexing.

## Why content search moved to snacks.picker

`<leader>fd` and `<leader>fg` were **both** bound to telescope's
`live_grep_args` - two keys, one identical picker - and the picker had two
problems that no amount of configuration fixes.

Every keystroke re-ran ripgrep. Narrowing a result set therefore meant
rewriting the regex, not filtering what was already on screen, because
`live_grep_args` has no mode in which the prompt filters results instead of
re-querying. And scoping a search to a directory or a filetype meant typing raw
ripgrep flags into the prompt from memory - powerful, but the only mechanism on
offer.

snacks.picker answers both:

- `<C-g>` freezes the result set and turns the prompt into a fuzzy filter over
  it, with fzf syntax (`'exact`, `'word'`, `^prefix`, `suffix$`, `!negate`,
  `foo | bar`) and field searches like `file:lua$ 'function`.
- `<A-h>` / `<A-i>` / `<A-r>` toggle hidden files, git-ignored files and regex
  live, with the state rendered in the dialog title.
- Raw ripgrep flags are still available, after a ` -- ` separator
  (`useQuery -- -t ts -g '!*test*'`), so nothing the live-grep-args extension
  provided was given up.
- `git_grep` gave the duplicated `<leader>fg` an actual job: `git grep` over
  tracked files only.
- `resume` restores the query, the cursor position and the multi-selection.
- `lines` is an excellent in-buffer search: fuzzy over the open buffer, with
  the match previewed in the real editor window.

### Ripgrep cannot fuzzy-match, which is the one thing this does not give you

`<leader>fd`'s prompt is a ripgrep pattern, not a fuzzy query: `foo bar`
searches for the literal string `foo bar`. The fuzzy matching lives behind
`<C-g>`, and it is fuzzy *refine* - narrowing a result set ripgrep already
produced - not fuzzy matching across the repo.

fff is the only engine considered here that does the latter, because it does
not shell out to ripgrep at all: it fuzzy-matches line content against its own
resident Rust index. That was weighed and rejected for content search, because
adopting it would have cost four things snacks provides and fff cannot:

| | snacks | fff 0.8.4 |
|---|---|---|
| git-tracked grep (`<leader>fg`) | `git_grep` | git-status filters are disabled for grep |
| in-buffer search (`<leader>ss`) | `lines` | cwd-scoped only, no current-buffer scope |
| resume (`<leader>fl`) | query + cursor + selection | no resume at all |
| hidden / ignored toggles | `<A-h>` / `<A-i>` | no such toggles |
| raw ripgrep flags | ` -- ` separator | impossible by construction |

Two of those gaps are worth stating precisely, because they are *not* version
lag and bumping the pin would not close them: fff's grep query parser is a bare
`split_whitespace()` with no quote syntax, so there is no `"exact"` in-query
form and exactness is reachable only by cycling modes with a key; and its
Neovim binding hardcodes zero context lines. Both are still true in fff's
latest release, not just the pinned 0.8.4.

### Why the earlier rejection of snacks.picker no longer applies

An earlier revision of this ADR rejected snacks.picker outright, on the grounds
that it replaces `vim.ui.select` - and therefore the code-action dialog - at the
same time as it replaces search, bundling a large behavioural change into a bug
fix.

That objection was about **bundling**, not about the picker, and it is answered
rather than ignored: `settings.picker.ui_select = false` keeps telescope-ui-select
owning code actions, so adopting snacks changes content search and nothing else.
Whether snacks should also take over `vim.ui.select`, the LSP pickers and
neoclip is a separate question, deliberately left open.

## The boundary

`programs/nvim/core/search/` splits along it. `file.nix` owns fff and the
telescope file pickers, `grep.nix` owns content search *and* the snacks engine
config - it is snacks' only consumer - `default.nix` owns the telescope engine
config that belongs to neither, and `shared.nix` holds the one `excludeDirs`
list that the `fd --exclude` flags and telescope's `file_ignore_patterns` are
both derived from. Those were previously two hand-maintained lists that had
already drifted. Snacks grep derives nothing from it: ripgrep honours
`.gitignore`, and the list was measured redundant there.

Adding a file picker means adding it to `file.nix`. Adding a content search
means adding it to `grep.nix`. Anything needing `vim.ui.select`, git-ignored
files, or recent files belongs on telescope.

## Consequences

### `<Tab>` navigates in every picker, and in snacks that fixes a real bug

`<Tab>`/`<S-Tab>` move through the candidate list and `<C-Space>` toggles
selection, in fff and in snacks alike. Neither does that by default: both bind
`<Tab>` to selection.

In snacks that default is not just inconsistent, it is a bug in practice. Stock
`<Tab>` is `select_and_next`, so tabbing down to the 5th match of `<leader>ss`
silently selects matches 1-4 on the way, and `<CR>` then jumps to the first
item of the selection (`actions.lua:47` takes `picker:selected()`; the cursor
is set from `items[1]`). It was reported as "Enter takes me back to the first
match" and reproduced headlessly: `<C-n>` x4 lands on the 5th match, `<Tab>` x4
on the 1st. `checks.nvim-search` now presses those keys and asserts the line.

**The two remaps point in opposite directions, and that is not a typo.** fff
reverse-renders under its bottom prompt, so its best match sits at the *bottom*
and moving visually up walks toward worse results - hence `<Tab>` ->
`move_up`. snacks' layouts are not reversed, so the best match is at the *top*
and moving down walks toward worse results - hence `<Tab>` -> `list_down`.
Same semantics, inverted mapping.

Rehoming selection to `<C-Space>` is mandatory, not cosmetic: it is what feeds
`<C-q>` and therefore `:cfdo`. In fff it also has to move because
`picker_ui.lua` binds `toggle_select` *after* `move_up`/`move_down` and would
otherwise silently win the conflict.

Everything else already agrees across all three engines: `<C-n>`/`<C-p>`,
arrows, `<CR>`, `<C-v>`, `<C-s>`, `<C-t>`, `<C-q>` and `<Esc>`. Telescope's
`<C-x>` for a horizontal split is the lone exception, and snacks does not bind
it at all.

### Live grep lagged at upstream defaults; `limit_live` is the fix

The first working version kept every snacks default and live grep lagged badly
on large repos. Two things were established before changing anything:

- **Ripgrep is not the bottleneck**: 50-60ms for a broad query over ~2600
  files, with `--hidden` costing about 5ms of that.
- **snacks is current**: v2.31.0 is the latest release and has no picker
  commits after it, so there is no upstream fix to pull in.

The cost is per streamed match. Each one is parsed in Lua, wakes the matcher
and is rendered (`core/finder.lua:155`), and `limit_live` - the cap on how many
a live search ingests - defaults to 10000. A broad query in a large repo
produces nearly that many on every update, which is the list-update overhead
described in [snacks discussion #950](https://github.com/folke/snacks.nvim/discussions/950).
Hitting the limit aborts the finder, so ripgrep stops too.

`limit_live = 1000` is the one performance setting. A query that reaches it is
too broad to read anyway: type more, or `<C-g>` to fuzzy-filter what is there.
`lines` is not live, so it is unaffected. `<A-p>` toggles the preview, the
maintainer's own suggestion in #950 if a search still feels slow.

Two other approaches were tried and reverted, and are recorded so they are not
tried again:

- **Non-live grep behind an up-front pattern prompt.** snacks hardcodes its
  input throttle by mode, 200ms live against 30ms non-live
  (`picker/core/input.lua:90`), which made non-live look like the fix. In use
  it was worse: a non-live grep only opens its window after the first match
  ([#2206](https://github.com/folke/snacks.nvim/issues/2206)), so `<leader>fd`
  appeared to do nothing at all.
- **The `ivy` layout for grep.** A bottom strip rather than the centred dialog.
  Dropped along with the non-live change in favour of stock behaviour.

If live grep still regresses, fzf-lua was ranked first on grep speed when the
engines were compared - matching runs in the `fzf` binary rather than Lua - and
is the obvious next step for `<leader>fd`/`<leader>fg`.

### Telescope lost its resume key

`<leader>fl` is `Snacks.picker.resume()`. There is no unified resume across
three engines, and the searches worth resuming are the long grep queries, not
the one-shot `<leader>fa` and `<leader>fe` finders. fff has no resume at all, so
`<leader>ff` always starts fresh.

### Freeform settings are the standing hazard, and a check guards them

Neither `plugins.fff.settings` nor `plugins.snacks.settings` types the keys this
config sets - nixvim gives snacks typed options for five of its sub-modules and
`picker` is not one of them - so a misspelled key is **silently dropped** and the
plugin runs on its defaults with nothing to show that it happened. fff is worse
still: its nixvim module has no `settingsOptions` at all, and its
`settingsExample` is stale against the pinned 0.8.4 (it shows
`key_bindings`/`select_file`; `conf.lua` reads `keymaps`/`select`).

`checks.nvim-search` (`programs/nvim/check.nix`) closes this for snacks. It
asserts the *resolved* picker config - `ui_select`, `limit_live`, the `<Tab>`
remap - that the stock defaults this config leans on are still stock, that
every content-search key dispatches to its source, and that no other snack was
switched on.

It also drives `<leader>ss` with real keystrokes against a fixture file and
asserts where `<CR>` lands and what `<C-q>` sends, because the `<Tab>` bug was
only visible that way. Anything added to `settings.picker` should get an
assertion there.

Anything set for **fff** still has to be checked against a running editor.

### Per-source config does not cascade

`grep`, `git_grep` and `grep_word` are separate snacks *sources* that share one
finder, and snacks resolves per-source config by name: anything set under
`grep` will not reach the others. Everything set today is global (`ui_select`,
`limit_live`, `win.*.keys`), which sidesteps this, but anything source-specific
added later has to be written for each.

### Query syntax differs per engine

fff's search box is fuzzy until the query contains a glob metacharacter, at
which point the pattern is anchored to the whole relative path and `*` crosses
`/`. `useViewModel` and `*use*ViewModel*` both find
`src/hooks/useLoginViewModel.ts`; a bare `use*ViewModel` finds nothing.

snacks' grep prompt is a ripgrep pattern, with raw flags after ` -- `; its
post-`<C-g>` prompt is fzf syntax. Telescope's prompts are fzf syntax via
`fzf-native`.

### Theming

catppuccin has an integration for snacks, defaulted to `enabled = false`, so
`theme.nix` asks for it. It has none for fff, which hardcodes dark-tuned hex
colours for its git-status highlight groups - and the
`highlight default link ... GitSignsAdd` fallback it writes immediately below
them never fires, because `highlight default` will not overwrite a group that is
already defined. `file.nix` re-links those groups for real, which is what makes
them legible on catppuccin latte.

Note that catppuccin's `setup()` **replaces** its options rather than merging
into them, so the `auto` theme branch - which re-runs `setup()` in Lua to pick a
flavour from the system appearance - discards everything nixvim wrote through
`settings` and has to repeat the snacks integration.

### Risks accepted

fff is young and effectively single-maintainer, and it reintroduces a persistent
index - the same class of thing that caused the original bug, mitigated by a
different mechanism.

snacks.nvim is a large, actively-developed suite pulled in for one of its
modules. The surface actually used is small and the rest stays dormant, but the
plugin updates as a whole.

Dropping `<leader>fF` left no telescope fallback for plain file finding;
`<leader>fa` is the nearest substitute.
