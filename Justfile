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

# Run all checks (lint + format + flake check)
check:
    just lint
    just format --ci
    nix flake check
