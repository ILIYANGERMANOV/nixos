# checks.qa: the /qa runtime headless, with nothing but its own commands on
# PATH - the wallet helper discovered through EIP-6963, connected, signing
# with a key generated for this run that the page never sees, forwarding the
# page's RPC and declining after a pause; `qa-wallet` reading the address and
# balances from a fake RPC; `waitForReceipt` against it; and a recorded video
# transcoded to H.264. Then the evidence tools and the shared session
# (`qa-check-tools.js`): the static lead-in trim, the contact sheet, one
# browser shared by separate probe processes, `expectState` and redaction.
# Linux only: the Darwin sandbox cannot launch Chromium.
{ pkgs }:

let
  playwright = import ./. { inherit pkgs; };
in
pkgs.runCommand "qa-check" { nativeBuildInputs = [ playwright.qa ]; } ''
  export HOME="$TMPDIR/home"
  mkdir -p "$HOME" "$TMPDIR/work"
  cd "$TMPDIR/work"
  qa-node ${./qa-check.js} "$TMPDIR/work"
  qa-node ${./qa-check-tools.js} "$TMPDIR/work"
  touch "$out"
''
