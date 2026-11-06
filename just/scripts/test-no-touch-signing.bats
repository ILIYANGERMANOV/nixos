#!/usr/bin/env bats
# shellcheck disable=SC2016 # a stub's body expands when the stub runs

load ../../programs/shell-check/test_helper

setup() {
  export WORK="$BATS_TEST_TMPDIR" HOME="$BATS_TEST_TMPDIR"
  mkdir -p "$WORK/signer/bin"
  stub nix 'echo "$WORK/signer"'
  stub hostname 'echo mac'
  stub date 'echo 20261106120000'
  # commit-tree records the signer and key it was handed; push records the ref.
  stub git 'case "$*" in
    *commit-tree*) echo "$*" >"$WORK/commit-tree"; echo abc123 ;;
    "push "*) echo "$*" >"$WORK/pushed" ;;
  esac'
  verification true valid
}

# GitHub reports verified $1 for reason $2; a DELETE records the ref it removed.
verification() {
  stub gh 'case "$*" in
    "repo view"*) echo owner/repo ;;
    "api -X DELETE "*) echo "$4" >"$WORK/deleted" ;;
    "api repos/owner/repo/commits/abc123 "*) echo "'"$1 $2"'" ;;
  esac'
}

test_signing() { bash "$BATS_TEST_DIRNAME/test-no-touch-signing.sh"; }

@test "signs with the no-touch signer and this host's key on top of origin/main" {
  run test_signing

  grep -qF -- "gpg.ssh.program=$WORK/signer/bin/yubikey-touch-ssh-keygen" "$WORK/commit-tree"
  grep -qF -- "-S$HOME/.ssh/id_ed25519_sk.pub -p origin/main" "$WORK/commit-tree"
}

@test "a verified signature passes and the scratch branch is deleted" {
  run test_signing

  [ "$status" -eq 0 ]
  [[ "$output" == *"verified: true"* ]]
  grep -qxF "push origin abc123:refs/heads/no-touch-test-mac-20261106120000" "$WORK/pushed"
  grep -qxF "repos/owner/repo/git/refs/heads/no-touch-test-mac-20261106120000" "$WORK/deleted"
}

@test "an unverified signature fails with GitHub's reason and still deletes the branch" {
  verification false invalid

  run test_signing

  [ "$status" -eq 1 ]
  [[ "$output" == *"reason:   invalid"* ]]
  [ -e "$WORK/deleted" ]
}

@test "a failed push deletes nothing" {
  stub git 'case "$*" in
    *commit-tree*) echo abc123 ;;
    "push "*) exit 1 ;;
  esac'

  run test_signing

  [ "$status" -ne 0 ]
  [ ! -e "$WORK/deleted" ]
}
