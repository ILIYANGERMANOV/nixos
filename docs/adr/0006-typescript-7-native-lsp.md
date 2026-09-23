# Two TypeScript language servers, routed by era

Neovim runs two TypeScript language servers side by side and lets the project
decide which one attaches. That looks like something to consolidate, so this
records why it is the intended shape, what it costs, and what would have to
change for one server to be enough.

`vtsls` serves TypeScript 6 and below. `tsc --lsp` serves TypeScript 7 and
above. Exactly one attaches to any project root, and no project configures
which.

## What broke

Opening a TypeScript 7 project produced a Lua error and no language server:

```
typescript-tools/tsserver_provider.lua:190:
  Cannot find tsserver executable in local project nor global npm installation.
```

`typescript-tools.nvim` does not speak LSP to TypeScript. It forks
`node_modules/typescript/lib/tsserver.js` and speaks the bespoke tsserver wire
protocol to it. TypeScript 7 is the Go port, and it ships no such file - the
`typescript` package is down to `lib/{tsc.js, getExePath.js, version.cjs}` and a
single `tsc` binary. The language service is now a Go program speaking LSP
directly, over `tsc --lsp --stdio`.

So the failure is structural. No setting on `typescript-tools.nvim` fixes it,
and the same applies to `typescript-language-server`, which exists only to fork
that file and translate between the two protocols.

## Why both eras still have to work

TypeScript 7 is not something a machine adopts all at once. At the time of
writing this repo's owner has one project on 7.0.2, two on 6.0.3, and four on
5.x. Every one of those still ships `lib/tsserver.js`; only the 7.x one does
not.

A single server was considered and rejected in both directions. Running
`tsc --lsp` everywhere would type-check TypeScript 5.3 code with TypeScript 7
semantics, so the editor would report diagnostics the project's own `tsc` never
emits. Running `vtsls` everywhere is simply impossible on 7.x - there is no
tsserver for it to wrap.

## How a root picks its server

The probe is the presence of `node_modules/typescript/lib/tsserver.js` under
the root, and that is the whole rule. It tests exactly the capability the two
servers disagree on, so there is no version string to parse and no semver
comparison to maintain, and a project flips era by itself the moment it
upgrades. Nothing per-project is written down anywhere.

Both servers get the same `root_dir` hook, differing only in the era they
answer for: it resolves the root from the package-manager lockfiles, then
returns without calling `on_dir` when the era is not its own. Declining is how
a server stays out of the way, so two servers can never claim one root and
produce doubled diagnostics and doubled completions.

A root with no lockfile above it - a loose `.ts` file - falls back to the
working directory, finds no classic service there, and lands on the native
server.

Version fidelity is handled per era. The native server prefers the project's
own `node_modules/.bin/tsc`, falling back to the Home Manager `typescript` only
where a project has not been installed yet. `vtsls` vendors its own TypeScript
(5.9.3 in nixpkgs 26.05), which would check a 6.0.3 project as 5.9.3, so
`vtsls.autoUseWorkspaceTsdk` makes it load the workspace copy instead. It finds
that copy at the root, which is exactly where `root_dir` has already proven a
classic service lives, so the lookup cannot fail for any root vtsls attaches to.

An explicit `typescript.tsdk` pointing at the same directory was written first
and then removed: with `autoUseWorkspaceTsdk` set, a TypeScript 6.0.3 project
reports `6.0.3` either way. Asking the running server which TypeScript it loaded
is the way to tell, since reading `client.settings` is misleading - Neovim
snapshots it before `before_init` can mutate it, so the key appears absent while
the server has it:

```
:lua =vim.lsp.get_clients{name="vtsls"}[1]
  :request_sync("workspace/executeCommand",
    { command = "typescript.tsserverRequest", arguments = { "status", {} } }, 5000, 0)
```

Check that against a project whose TypeScript differs from the bundled version.
A 5.9.3 project cannot distinguish the two.

## Consequences

**TypeScript 7 roots have no refactors.** Measured against a running
`tsc --lsp` 7.0.2 rather than taken from release notes, it advertises
`quickfix`, `source.organizeImports`, `source.removeUnusedImports`,
`source.sortImports` and `source.fixAll` - and no `refactor` kind at all. So
extract-function, extract-variable, extract-type and move-to-file are simply
absent there; `<leader>ca` offers quickfixes and the source actions. `vtsls`
advertises `refactor`, `refactor.extract` and `refactor.rewrite`, so projects
on 6.x and below keep them. Re-check with:

```
:lua =vim.lsp.get_clients{name="tsc"}[1].server_capabilities.codeActionProvider
```

**`source.organizeImports` is the only code action both advertise.** The native
server has `source.removeUnusedImports` and `source.sortImports` that `vtsls`
lacks; `vtsls` has no remove-only kind. `<leader>oi` therefore uses
`source.organizeImports` in both eras, which is a behaviour change: the
`TSToolsRemoveUnused` command it replaces removed unused imports without
sorting, so the first use in any project produces a larger diff than before.

**Semantic tokens are inert on 7.x.** `tsc --lsp` returns an empty legend
(`tokenTypes: []`), where `vtsls` returns twelve token types with modifiers.
Treesitter highlighting is unaffected, so this is invisible in practice.

**Go-to-source-definition moved.** `vtsls` exposes it as an LSP command; the
native server has no `executeCommandProvider` at all and offers
`experimental.customSourceDefinitionProvider` instead. Nothing in this config
binds it today.

**Diagnostics arrive differently.** The native server is pull-model
(`diagnosticProvider`, with `workspaceDiagnostics: false`); `vtsls` pushes.
Neovim 0.12 handles both, but only open buffers are ever diagnosed on 7.x.

**Formatting had to be taken away from both.** `tsc`, `vtsls` and the biome
language server all advertise `documentFormattingProvider`, while conform-nvim
runs biome's CLI on save. Both TypeScript servers have the capability stripped
in `on_attach` so no LSP-driven format path can reformat against tsserver
defaults instead of `biome.json`.

## Why `tsc` is hand-written and `vtsls` is not

nvim-lspconfig 2.9.0, which the pinned nixvim carries, ships `lsp/vtsls.lua`
but no `lsp/tsc.lua` - upstream added `tsc` later, and deprecated its earlier
`tsgo` entry in favour of it. So `vtsls` inherits `cmd`, `filetypes` and root
markers from upstream and overrides only what this repo decides, while `tsc`
declares every field itself.

Bumping nixvim off `nixos-26.05` to inherit `lsp/tsc.lua` was rejected: it drags
every other plugin in the editor with it, against a channel this repo pins
deliberately (see `0004-darwin-tracks-the-darwin-channel.md`). Reusing the
pinned `tsgo.lua` with an overridden `cmd` was rejected too - the server would
report as `tsgo` in `:checkhealth` while running `tsc`, and it inverts the
direction upstream has since moved.

Both servers are configured through `lsp.servers` rather than
`plugins.lsp.servers`, because the latter only has options for names lspconfig
ships a definition for. The two are the same thing underneath -
`plugins.lsp.servers.<name>` is an alias layer writing into `lsp.servers` - so
`biome`, `html` and `cssls` were left on the API they were already using rather
than churned for symmetry.

## What is checked, and what is not

`checks.nvim-typescript` builds the real editor, creates one fixture root per
era plus a loose file, and asserts that the expected server claims each root
and the other declines. It also asserts that the native server prefers a
project-local `tsc` and falls back otherwise.

It deliberately starts no language server, which is its limit: it proves
routing, not that a server then starts. Two things were found while writing it
and are worth knowing before changing it. `vim.fs.root` returns `nil` for any
buffer whose `buftype` is not `""`, so a scratch buffer makes every `root_dir`
fall through to its cwd fallback and the whole check pass vacuously. And a Lua
error inside `-c luafile` aborts the chunk while leaving Neovim's exit code at
`0`, so the check writes a sentinel file as its last statement and the builder
fails when that file is absent. Both failure modes report a broken config as
clean, which is the same hazard `just darwin-cache-check` guards against.

## Revisiting

The trigger to collapse this back to one server is TypeScript 7 becoming the
floor across every project that gets opened. At that point `vtsls`, its tsdk
wiring and the era probe all come out, and `tsc` loses its `root_dir` override.
The refactor gap should close before then and is worth re-checking
independently, but it is not what justifies two servers - the version skew is.
