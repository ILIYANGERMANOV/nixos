# ─── Nix Darwin - Cache Guard ────────────────────────────────────────────────
# Refuses a dependency bump whose build plan contains something too expensive to
# build locally. Run it before pulling a bump; CI runs it on every PR.
# See docs/adr/0004-darwin-tracks-the-darwin-channel.md for why this exists.

# Fail if rebuilding macos-main would build anything on the expensive-builds denylist.
darwin-cache-check:
    #!/usr/bin/env bash
    set -euo pipefail

    main() {
        local denylist plan offenders

        denylist="$(denylist_regex)"
        assert_guard_works "$denylist"

        plan="$(build_plan)"
        grep -E 'will be (built|fetched)' <<<"$plan" || true

        offenders="$(derivations_to_build <<<"$plan" | grep -E "$denylist" || true)"
        [ -z "$offenders" ] || reject "$offenders"

        echo "darwin-cache-check: nothing on the denylist would be built."
    }

    # macos-main and macos-work share every module and differ only in hostname,
    # user and nix.enable, so one host covers both. Evaluating an aarch64-darwin
    # closure needs no darwin builder: --dry-run only queries substituters, so
    # this runs on the Linux CI runner. nix prints the plan to stderr.
    build_plan() {
        nix build --dry-run .#darwinConfigurations.macos-main.system 2>&1
    }

    # A cold store makes "will be built" mean "substitutable nowhere", which is
    # exactly the cache-miss set we care about. Match the headers without their
    # trailing colon: the fetch one reads "will be fetched (3.3 GiB download...):".
    derivations_to_build() {
        awk '/will be built/ { inside = 1; next } /will be fetched/ { inside = 0 } inside' \
            | strip_store_prefix
    }

    denylist_regex() {
        grep -vE '^[[:space:]]*(#|$)' just/nix-darwin/expensive-builds.deny | paste -sd'|' -
    }

    strip_store_prefix() {
        sed 's#^.*/[a-z0-9]\{32\}-##'
    }

    # Both ways this guard can break are silent: a denylist that matches nothing
    # and an extractor that yields nothing each report every plan as clean. Run
    # the real pipeline over a plan with known answers before trusting it.
    assert_guard_works() {
        local denylist="$1" flagged
        flagged="$(sample_plan | derivations_to_build | grep -E "$denylist" || true)"

        if ! grep -qx 'swift-5\.10\.1\.drv' <<<"$flagged"; then
            refuse_to_vouch "swift was not flagged in a plan that builds it"
        fi
        if grep -q 'cargo-' <<<"$flagged"; then
            refuse_to_vouch "the rust-overlay cargo tarball was flagged; herdr always builds it"
        fi
        if grep -q 'ghc-' <<<"$flagged"; then
            refuse_to_vouch "the fetched list leaked into the built list"
        fi
    }

    # A build section holding one denylisted derivation and one lookalike that
    # must not match, followed by a fetch section that must be ignored entirely.
    sample_plan() {
        cat <<'PLAN'
    these 2 derivations will be built:
      /nix/store/zdgs26mvv9ps946j4i4n062msxw244p7-swift-5.10.1.drv
      /nix/store/wf2w7wal5lnw5zlfxcvhg2kygwiwgsr5-cargo-1.96.1-aarch64-apple-darwin.drv
    these 1 paths will be fetched (1.0 GiB download, 2.0 GiB unpacked):
      /nix/store/hcvahi0qri0sl0kw6c3xsii9cslmhn0k-ghc-9.10.3
    PLAN
    }

    refuse_to_vouch() {
        echo "darwin-cache-check: self-test failed - $1." >&2
        echo "The guard cannot be trusted in this state; fix it before relying on a pass." >&2
        exit 1
    }

    reject() {
        echo "" >&2
        echo "darwin-cache-check: these are on the denylist and would be built locally:" >&2
        printf '%s\n' "$1" | sed 's/^/  /' >&2
        echo "" >&2
        echo "That is hours of rebuild, not minutes. Do not merge this bump - wait for a" >&2
        echo "nixpkgs rev whose darwin closure is in the cache, or add a substituter that" >&2
        echo "has it. See docs/adr/0004-darwin-tracks-the-darwin-channel.md." >&2
        exit 1
    }

    main
