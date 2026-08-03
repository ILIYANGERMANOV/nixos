set shell := ["bash", "-eo", "pipefail", "-c"]

import 'just/secrets.just'
import 'just/ssh.just'
import 'just/nixos/live-iso.just'
import 'just/nixos/post-boot.just'
import 'just/nix-darwin/install.just'
import 'just/nix-darwin/post-install.just'

# Show available recipes
default:
    @just --list

# Lint all Nix files
lint:
    statix check .
    deadnix .

# Format all Nix files (nixfmt); pass --ci to check without writing
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

# Run all checks (lint + format + spell + flake check)
check:
    just lint
    just format --ci
    just typos
    nix flake check
