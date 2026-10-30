# Neovim

## Neovim + LSP Architecture

**Neovim owns LSP client config. Project dev shells own LSP binaries.**

- `programs/nvim/languages/*.nix` — LSP client config only (`package = null` on all servers except `nil_ls`). No `extraPackages` for language tooling.
- `modules/home/languages/*.nix` — global LSP binaries and dev tools installed via Home Manager (e.g. `hls`, `fourmolu`, `vtsls`).
- `nil_ls` is the only LSP with its binary baked into Neovim — Nix files have no project dev shell.

**direnv** (enabled in `modules/home/default.nix` via `programs.direnv.nix-direnv`) auto-activates a project's dev shell on `cd`. Project flakes only need a `.envrc` containing `use flake`. This puts project-pinned LSP binaries (e.g. GHC-matched HLS) on PATH, which Neovim's lspconfig picks up automatically.

Project flakes have **no dependency on this nixos repo** — they are standalone.

**Context-aware keymaps** (`programs/nvim/core/context-aware-keymaps.nix`) provide a single `<leader>tt` that dispatches to the right test runner at runtime. The registry (`_G.ContextRunners`) is initialized in `extraConfigLuaPre` (runs before all plugin/language Lua) to avoid ordering issues. Each language file registers its runner via `_G.RegisterContextRunner` in `extraConfigLua`.

## TypeScript: two servers, routed by era

**`vtsls` serves TypeScript <= 6, `tsc --lsp` serves TypeScript 7+, and the
project decides which one attaches.** Two servers by design - see
`docs/adr/0006-typescript-7-native-lsp.md`.

TypeScript 7 is the Go port and ships no `lib/tsserver.js`. Anything that forks
that file (`typescript-tools.nvim`, `typescript-language-server`) cannot serve a
7.x project at all, which is why both are gone. The era probe is the presence of
that one file under the root: it tests exactly the capability the two servers
disagree on, so **never replace it with a version comparison**. A project flips
era on its own when it upgrades, and nothing per-project is configured.

Both servers share one `root_dir` hook in `programs/nvim/languages/typescript.nix`,
differing only in the era they answer for. A server declines a root by returning
without calling `on_dir` - that is what keeps two servers from claiming one root
and doubling every diagnostic and completion.

- `tsc` is declared in full: lspconfig 2.9.0 ships `lsp/vtsls.lua` but no
  `lsp/tsc.lua`. `vtsls` inherits upstream's `cmd`, `filetypes` and root markers
  and overrides only `root_dir`, `settings` and `on_attach`.
- These two use `lsp.servers`, not `plugins.lsp.servers`, because the latter
  only has options for names lspconfig defines. They are the same thing
  underneath, so `biome`, `html` and `cssls` stay on the older API.
- `vtsls` vendors its own TypeScript (5.9.3), so `vtsls.autoUseWorkspaceTsdk`
  makes it load the project's copy. Without it a TS 6 project is checked as
  5.9.3. An explicit `typescript.tsdk` alongside it was verified redundant.
  Confirm with `typescript.tsserverRequest` `status` against a project whose
  TypeScript is **not** 5.9.3 - `client.settings` does not show it.
- Both have `documentFormattingProvider` stripped in `on_attach`. **biome owns
  formatting** for every filetype they claim, through conform-nvim.
- On 7.x roots there are **no `refactor` code actions** - upstream advertises
  none yet - and `source.organizeImports` is the only kind both eras share, so
  that is what `<leader>oi` sends.

`nix flake check` runs `checks.nvim-typescript` (`programs/nvim/check.nix`,
which returns every Neovim check over one shared editor build). It builds the
real editor and asserts the routing against fixture roots, and starts no
server. Two traps if you edit it: `vim.fs.root` returns `nil` for any
buffer whose `buftype` is not `""`, and a Lua error under `-c luafile` leaves
Neovim's exit code at `0`. Both make a broken config look clean, which is why
the assertions write a sentinel file the builder checks for.

## Neovim Search

**Three engines, split by what they search**: fff owns file search
(`<leader>ff`), snacks.picker owns content search (`<leader>fd`, `fg`, `fw`,
`ss`, `fl`), telescope owns everything else. By design, not a half-finished
migration - see `docs/adr/0003-picker-engines.md`.

`programs/nvim/core/search/` splits along that boundary:

- `file.nix` - fff plus the telescope file pickers (`<leader>fa`, `fe`, `fr`).
- `grep.nix` - content search, and the snacks engine config because it is
  snacks' only consumer.
- `default.nix` - telescope engine config belonging to neither (`ui-select`,
  `fzf-native`, `file_ignore_patterns`), plus `<leader>fl` and `<leader>nh`.
- `shared.nix` - a plain function, **not** a module, so it can export helpers.
  Holds the single `excludeDirs` list that both the `fd --exclude` flags and
  telescope's `file_ignore_patterns` are derived from. Add an exclusion here,
  never in one consumer. Snacks grep does not use it - see below.

Anything needing `vim.ui.select` (code actions), recent files, or git-ignored
files must stay on telescope. **`ui_select = false` is set deliberately**:
snacks defaults it to `true` and would take over every code-action dialog, which
is a separate decision from content search and is left open.

### Content search: stock snacks plus three settings

`settings.picker` sets `ui_select = false`, `limit_live = 1000` and the
`<Tab>` remap. Everything else is an upstream default: live ripgrep in the
centred dialog with a preview, raw rg flags after ` -- ` (`foo -- -t ts`),
`<C-g>` to freeze the results and fuzzy-filter them with fzf syntax,
`<A-h>`/`<A-i>`/`<A-r>` toggles, `<A-p>` to toggle the preview, `<C-q>` to the
quickfix list.

- **`limit_live = 1000`** is the performance fix. Upstream's 10000 made live
  grep lag on large repos: each streamed match is parsed in Lua, wakes the
  matcher and is rendered, and a broad query produces nearly 10000 on every
  update. Ripgrep itself was measured at 50-60ms and is not the bottleneck.
  Hitting the limit aborts the finder, so rg stops too. `lines` is not live and
  is unaffected.
- **`<Tab>`/`<S-Tab>` navigate, `<C-Space>` selects**, as in fff. Stock `<Tab>`
  is `select_and_next`, which was a real bug: tabbing to the 5th match of
  `<leader>ss` selected matches 1-4 and `<CR>` jumped to the first. **The fff
  and snacks remaps point in opposite directions and that is not a typo** - fff
  reverse-renders (best match at the bottom), snacks does not (best match at
  the top).
- **Hidden files are off.** Telescope passed `--hidden`, so `.github/` and
  `.env*` need `<A-h>` or `-- --hidden` now.
- **Nothing filters by directory.** ripgrep honours `.gitignore`, and
  `excludeDirs` was measured redundant for grep. The fix if a project does not
  gitignore its build output is `sources.grep.exclude = shared.excludeDirs`.

**Do not make grep non-live, and do not add a pattern prompt.** It was tried:
snacks' live throttle is hardcoded at 200ms against 30ms non-live, which makes
non-live look faster, but a non-live grep only opens its window after the first
match ([snacks#2206](https://github.com/folke/snacks.nvim/issues/2206)), so
`<leader>fd` appeared to do nothing. If live grep regresses again, the next step
is fzf-lua for `<leader>fd`/`<leader>fg`, not tuning snacks further. The pinned
snacks (v2.31.0) is the latest release.

**Per-source config does not cascade.** `grep`, `git_grep` and `grep_word` are
separate sources, resolved by name. Everything set today is global; anything
source-specific added later has to be written for each.

### Freeform settings, and the check that guards them

Neither `plugins.fff.settings` nor `plugins.snacks.settings` types the keys this
config sets - nixvim gives snacks typed options for five sub-modules and
`picker` is not one of them - so a misspelled key is **silently ignored** rather
than failing the build. fff has no `settingsOptions` at all and its
`settingsExample` is stale against the pinned version.

`nix flake check` runs `checks.nvim-search` (`programs/nvim/check.nix`), which
builds the real editor and asserts the **resolved** picker config (`ui_select`,
`limit_live`, the `<Tab>` remap), the stock defaults this config leans on,
every key's dispatch, and that no other snack got switched on. It also **drives
`<leader>ss` with real keystrokes** against a fixture file and asserts where
`<CR>` lands and what `<C-q>` sends, because the `<Tab>` bug was only visible
that way. Check bodies call `finish()` when done (with a 30s timeout) precisely
so they can wait on feedkeys. **Add an assertion there for anything you add to
`settings.picker`.**

Anything set for **fff** has no such guard: verify it by running the built
Neovim, not by trusting evaluation.
