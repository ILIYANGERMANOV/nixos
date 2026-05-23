set shell := ["bash", "-eo", "pipefail", "-c"]

import 'just/secrets.just'
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

# Run all checks (lint + flake check)
check:
    just lint
    nix flake check
