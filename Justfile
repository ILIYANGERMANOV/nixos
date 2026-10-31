set shell := ["bash", "-eo", "pipefail", "-c"]

import 'just/secrets.just'
import 'just/ssh.just'
import 'just/nixos/live-iso.just'
import 'just/nixos/post-boot.just'
import 'just/nix-darwin/install.just'
import 'just/nix-darwin/post-install.just'
import 'just/nix-darwin/cache-check.just'
import 'just/software-factory.just'

# Show available recipes
default:
    @just --list

# Lint all Nix files
lint:
    statix check .
    deadnix --fail .

# The rules live in deslop/rules/; `deslop explore .` draws the graph into
# deslop/diagram/index.html. See docs/adr/0008-deslop-enforces-the-architecture.md.
#
# Check the module graph against the architecture rules
architecture:
    deslop check .

# Format all files through treefmt; pass --ci to check without writing
format *ARGS:
    nix fmt -- {{ ARGS }}

# `--inputs-from .` resolves nixpkgs through flake.lock, so this is the same
# build the `typos` flake check runs in CI. Runs unwrapped, so it sees only the
# committed .typos.toml — never the private global allowlist, exactly like CI.
#
# Spell check all files (pinned to flake.lock; identical to CI)
typos *ARGS:
    nix run --inputs-from . nixpkgs#typos -- {{ ARGS }}

# Holds words that must not be disclosed, so it is committed nowhere — seeded
# once by home activation, then left unmanaged. Path mirrors programs/typos,
# which is the source of truth. Note that already-running Neovim instances keep
# the old list until their typos_lsp restarts: <leader>ad does that for you,
# editing by hand does not.
#
# Edit the private global typos allowlist in Neovim
typos-edit:
    #!/usr/bin/env bash
    set -euo pipefail
    allowlist="$HOME/.config/typos/typos.toml"
    if [ ! -e "$allowlist" ]; then
        echo "No global allowlist yet — run darwin-rebuild switch to seed it." >&2
        exit 1
    fi
    nvim "$allowlist"

# `nix flake check` spends most of its time evaluating every host; this builds
# only the `checks` derivations, `typos` among them, so it is the mid-work gate
# and `check` stays the final one.
#
# Run the fast checks (lint + format + every flake check, no host evaluation)
quick-check: lint architecture (format "--ci") (_build-checks ".*")

# Prints `All good (N)`, or every failure in full and exits nonzero, so never
# pipe it through grep. See docs/adr/0009-tech-checks.md.
#
# Run one technology's checks, every `<NAME>-*` flake check, with no host evaluation
tech NAME: (_build-checks (NAME + "-.*"))

# Builds this system's checks whose name matches `pattern`. Matching nothing
# fails: a typo in a group name must not pass with nothing built. `-L` and
# `--keep-going` report every failure whole: nix's own tail stops at 25 lines,
# and `log-lines` is a setting only trusted users may change.
[private]
_build-checks pattern:
    #!/usr/bin/env bash
    set -euo pipefail
    system=$(nix eval --impure --raw --expr builtins.currentSystem)
    names=$(nix eval --raw ".#checks.$system" --apply \
      'cs: toString (builtins.filter (n: builtins.match "{{ pattern }}" n != null) (builtins.attrNames cs))')
    [ -n "$names" ] || { echo "no checks match {{ pattern }} on $system" >&2; exit 1; }
    nix build --no-link --keep-going -L $(printf ".#checks.$system.%s " $names)
    echo "All good ($(wc -w <<<"$names"))"

# Run all checks (lint + architecture + format + spell + flake check)
check:
    just lint
    just architecture
    just format --ci
    just typos
    nix flake check
