# Scripts get checks per technology, and x86_64 gates deploys

Agents here maintain Python, shell, JavaScript and Lua as well as Nix, but
`just check` is the only gate that sees them all, and it takes minutes. An agent
editing one script had no fast answer, and CI built aarch64-linux alone while
the factory runs x86_64-linux. This ADR records the frame the per-technology
checks plug into.

## Groups are a name prefix

Each check is `<tech>-<kind>`, such as `shell-actionlint`, in
`programs/tech-checks/`. `checks.<system>.<name>` must be a derivation, so a
nested group is not possible: the prefix is the group.

`just tech <tech>` builds every `<tech>-*` check for this system, and the `tech`
matrix job runs one `just tech` per technology in parallel, with no path filter.
A filter would have to list `flake.lock`, `flake.nix` and `programs/tech-checks/`
too, and forgetting one hides a failure, while Nix cannot skip work in a job with
no shared store.

The contract comes from Deslop's ladder: `All good (N)`, or every failure
verbatim and a nonzero exit. A group with no checks fails, because a typo in a
matrix value would otherwise pass with nothing built.

A tech check takes source through `lib.fileset`, evaluates no host and uses no
import from derivation. That is what keeps a group to seconds, and a commit that
touches none of its files reuses the store path on the box.

Shell has six: `shell-actionlint` (workflows), `shell-lint` (every `.sh`, `.bats`
and `.bash`), `shell-format` (shfmt and `just --fmt`), `shell-just` (recipes, and
no `{{ }}` on a sudo line), `shell-embedded` (wrappers no other check builds) and
`shell-tests` (the software factory's bats suites). The lint rules live in
`programs/shell-check`, shared with `writeShellApplication`.

`shell-tests` is the one that runs what it checks. It needs only `pkgs`, so it
stays a tech check, and it replaced `checks.software-factory`. Its suites run one
at a time and take most of a group's minute, on the commits that change them.

`shell-embedded` is the one that needs flake inputs: `flake.nix` calls
`adapters/claude-code.nix` and hands the result in, with synthetic secret paths
so a wrapper's secret branches are linted too. It still evaluates no host. It
exists on Linux only, as `llm-agents` has no x86_64-darwin package.

## Additive: existing tests stay where they are

Tech checks are ordinary flake checks, so `nix flake check` in `check` builds
them too. That duplicates a few seconds of lint.

| Option | Cost | Verdict |
|---|---|---|
| A: new checks only, existing tests stay in `check` | small duplicate | Chosen |
| B: alias existing tests into groups too | `qa` runs twice, about 68 s | Only if per-technology failure signal proves worth it |
| C: split `check`, replacing `nix flake check` with host evals plus groups | fastest, but the deploy gate must be rewritten | Later, separately |

## The deploy gate names three jobs

`deploy-factory.yml` compares an exact string of job conclusions, so a job
outside it does not gate a deploy.

- `checks-x86_64` is in the gate. `check` runs on aarch64-linux, which is not the
  factory's system, and `nvim-kotlin` exists only on x86_64. A check red on
  x86_64 alone would otherwise reach the box. The job runs `just quick-check`
  on `ubuntu-24.04`.
- The `tech` jobs are not in the gate, and need not be. Every tech check is a
  flake check, so `check` and `checks-x86_64` already build it. A tech check
  outside `checks` would gate nothing, which is why none may live anywhere else.
- A new job must never reuse one of these three names: it would break the
  string compare.

No job is a required check in the ruleset. The gate and convention enforce CI.

## One formatter door

`formatter` is `pkgs.treefmt.withConfig` in `programs/tech-checks/formatter.nix`,
with the same settings as nixfmt-tree. A language adds an entry, no flake input
and no git hook, and `just format --ci` in `just check` enforces all of them.
treefmt-nix would be a new input for presets worth three lines each, and hooks
can be skipped, so CI must run the check anyway.

## CI matches the hosts

`modules/nix.nix` sets `allow-import-from-derivation = false`. Every job in
`check.yml` sets it too, so an import from derivation cannot pass CI and then fail on a host.

## TypeScript is ES modules, with its tools from nixpkgs

`ts-lint`, `ts-types` and `ts-test` cover `programs/playwright`.

- `verbatimModuleSyntax` refuses `import` in a CommonJS file, so the sources are
  ES modules. The compiled packages sit side by side in `lib/node_modules`,
  because an ES module resolves by directory and ignores NODE_PATH. A `/qa`
  script keeps its `require`.
- `tsgo` (TypeScript 7) and Biome come from nixpkgs. In the lock file, `typescript`
  would resolve as viem's optional peer and ship in the runtime closure, native
  binary included.
- `biome.json` sits at the repository root: Biome refuses a nested root
  configuration, and treefmt runs from the root.

## Lua is linted where it lives, in Nix strings

`lua-lint` runs selene and `stylua --check` on the Lua under `programs/nvim`
until #261 moves it to real files. It evaluates the modules without nixvim and
walks the values, so interpolations are rendered and `''` escapes resolved, which
a text extractor would have to redo.

- A value under `extraConfigLua*`, `luaConfig`, `onAttach`, `extraFiles` or
  `__raw`, a `<cmd>lua` keymap, or a plain string that looks like a call or a
  `function (` is Lua. A function value aborts the walk, since it could hide Lua.
- Fragments go in `scripts/` or `commands/`, by kind. A command is the Lua of one
  keymap, so stylua checks it with a wide column limit: `find_command` renders
  far past the usual one.
- A source whose markers, matched in any case, differ from its marked fragments
  fails evaluation, as does a fragment or line count under a floor, so a broken
  walk cannot pass on little or nothing. The comparison is exact and per file,
  with a named allowance for a helper that renders one marker per call, so a
  branch the walk cannot see, such as `optionalAttrs isDarwin`, fails too.
- `check.nix` stays out: it is test code, and evaluating it builds nixvim.
- Its dynamic `import` and `readFile` are baselined, as ADR 0008 says.
