# ─── Cache Guard ─────────────────────────────────────────────────────────────
# Refuses a dependency bump whose build plan contains something too expensive to
# build locally. Run it before pulling a bump; CI runs it on every PR.
# See docs/adr/0004-darwin-tracks-the-darwin-channel.md for why this exists.
#
# A binary cache is keyed per Nix system (CPU + OS), so each recipe is named by
# the system it checks. --dry-run only queries substituters, so any system's
# plan evaluates on a Linux CI runner, with no builder for that system.

# macos-main and macos-work share every module and differ only in hostname,
# user and nix.enable, so one host covers both.
#
# Fail if rebuilding macos-main would build anything on the expensive-builds denylist.
cache-check-aarch64-darwin: (_cache-check "cache-check-aarch64-darwin" ".#darwinConfigurations.macos-main.system")

# Fail if rebuilding software-factory would build anything on the expensive-builds denylist.
cache-check-x86_64-linux: (_cache-check "cache-check-x86_64-linux" ".#nixosConfigurations.software-factory.config.system.build.toplevel")

# The guard itself, for any host: `$label` names the calling recipe in its
# output, `$installable` is the system to plan. The denylist is
# platform-agnostic, only the flake attribute differs. Python comes pinned
# through flake.lock: a fresh machine or a CI runner has none of its own to
# trust. The logic and its tests are cache_check.py, beside this file.
[private]
_cache-check $label $installable:
    @nix run --inputs-from . nixpkgs#python3 -- just/cache-check/cache_check.py "$label" "$installable" just/cache-check/expensive-builds.deny
