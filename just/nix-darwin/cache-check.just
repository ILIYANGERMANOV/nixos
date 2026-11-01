# ─── Nix Darwin - Cache Guard ────────────────────────────────────────────────
# Refuses a dependency bump whose build plan contains something too expensive to
# build locally. Run it before pulling a bump; CI runs it on every PR.
# See docs/adr/0004-darwin-tracks-the-darwin-channel.md for why this exists.

# macos-main and macos-work share every module and differ only in hostname,
# user and nix.enable, so one host covers both. Evaluating an aarch64-darwin
# closure needs no darwin builder: --dry-run only queries substituters, so
# this runs on the Linux CI runner.
#
# Fail if rebuilding macos-main would build anything on the expensive-builds denylist.
darwin-cache-check: (_cache-check "darwin-cache-check" ".#darwinConfigurations.macos-main.system")

# The guard itself, for any host: `$label` names the calling recipe in its
# output, `$installable` is the system to plan. software-factory reuses it -
# the denylist is platform-agnostic, only the flake attribute differs. Python
# comes pinned through flake.lock: a fresh machine or a CI runner has none of its
# own to trust. The logic and its tests are cache_check.py, beside this file.
[private]
_cache-check $label $installable:
    @nix run --inputs-from . nixpkgs#python3 -- just/nix-darwin/cache_check.py "$label" "$installable" just/nix-darwin/expensive-builds.deny
