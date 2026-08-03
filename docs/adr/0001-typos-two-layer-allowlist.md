# Two-layer typos allowlist, one layer deliberately unmanaged

`typos` runs on three surfaces (CLI, Neovim LSP, CI gate) and needs somewhere to
record false positives. Because **this repo is public**, false positives hit while
working in private repos — client names, internal codenames — cannot be committed
here. So there are two layers: a committed `.typos.toml` per project, and a
mutable, untracked `~/.config/typos/typos.toml` for words whose disclosure
matters. The private layer is intentionally **not** Home Manager managed, which is
a deliberate deviation from this repo's declarative-by-default rule.

## Why the private layer can't be Nix-managed

Two independent reasons, either one sufficient:

1. **Disclosure.** A store-built config would have to be generated from something
   committed to this public repo — the exact thing the layer exists to avoid.
2. **Mutability.** The `<leader>ad` keymap appends the flagged word to the
   allowlist. A read-only store path cannot be appended to.

Home Manager therefore *seeds* the file when it is absent and never touches it
again. This is a one-time seed, not a managed value: later improvements to the
seed in this repo do not reach already-provisioned machines. After that it is
edited only by hand — `<leader>ad` from a typo in Neovim, or `just typos-edit`.

## Why `--config` and not a file in `$HOME`

typos' ancestor walk stops at the first config it finds:

```rust
if !self.isolated {
    for ancestor in cwd.ancestors() {
        if let Some(derived) = Config::from_dir(ancestor)? {
            config.update(&derived);
            break;
        }
    }
}
```

The walk ignores VCS roots and runs all the way to `/`, so a `~/typos.toml` *would*
be discovered — but only for projects that have no config of their own. It would
appear to work and then silently stop the moment a project grew a `.typos.toml`,
including this one. The explicit `--config` / `init_options.config` channel is the
only mechanism that genuinely layers: it loads into typos' *override* layer, where
`extend-words` from both layers merge.

## Consequences

- **Accepted local/CI divergence.** The private layer is invisible to CI by
  design, so a globally allowed word can make a local run pass while CI fails.
  `just typos` runs unwrapped against the same pinned build CI uses, which is the
  intended way to catch this before pushing.
- **The global `extend-exclude` is the sharper edge of that.** It can hide a whole
  file locally that CI still scans, so it is kept to machine-generated and
  encoded content only (`*.lock`, `*.age`, `secrets/**`).
- **No backup.** The private allowlist is the one piece of machine state that is
  untracked and unbacked-up. Encrypting it with the repo's existing SOPS setup was
  considered and rejected: it would return the file to the store, immutable, and
  break `<leader>ad` entirely.
- **typos is pinned** to the locked nixpkgs in both the flake check and `just
  typos`, because its dictionary grows every release and a floating version could
  turn CI red with no change to the repo. The corollary is that bumping
  `flake.lock` *can* legitimately surface new findings: that is the pin working as
  intended, and the fix is to allowlist the words, not to unpin typos.
