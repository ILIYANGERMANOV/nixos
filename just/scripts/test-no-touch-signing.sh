#!/usr/bin/env bash
# Does GitHub mark a tapless signature from this host's YubiKey key Verified?
# Signs one empty commit with the no-touch signer this checkout would deploy,
# pushes it to a scratch branch, asks GitHub, then deletes the branch. Works
# before the option is deployed. The commit is built with commit-tree on top
# of origin/main, so no local branch, index or working tree is touched.
# Run from the repository root (just does).
set -euo pipefail

key="$HOME/.ssh/id_ed25519_sk.pub"
repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
host=$(hostname -s)
stamp=$(date +%Y%m%d%H%M%S)
branch="no-touch-test-$host-$stamp"

# The real wrapper, built from this checkout with the option on.
# shellcheck disable=SC2016 # ${...} is Nix interpolation, not shell
signer=$(nix build --no-link --print-out-paths --impure --expr '
  (import ./programs/yubikey-touch-sound {
    pkgs = (builtins.getFlake (toString ./.)).inputs.nixpkgs.legacyPackages.${builtins.currentSystem};
    noTouchSigning = true;
  }).sshKeygen')/bin/yubikey-touch-ssh-keygen

echo "Signing an empty commit with $key - no tap should be needed."
start=$SECONDS
sha=$(git -c gpg.format=ssh -c gpg.ssh.program="$signer" \
  commit-tree -S"$key" -p origin/main -m "no-touch signing test" "origin/main^{tree}")
echo "Signed in $((SECONDS - start))s: $sha"

delete_branch() { gh api -X DELETE "repos/$repo/git/refs/heads/$branch" >/dev/null; }
echo "Pushing to $branch (SSH auth: tap when asked)."
git push origin "$sha:refs/heads/$branch"
trap delete_branch EXIT

verification=$(gh api "repos/$repo/commits/$sha" \
  --jq '.commit.verification | "\(.verified) \(.reason)"')
read -r verified reason <<<"$verification"
echo "verified: $verified"
echo "reason:   $reason"
[ "$verified" = true ]
