# checks.qa: the /qa runtime headless, with nothing but its own commands on
# PATH - the wallet helper discovered through EIP-6963, connected, signing
# with a key generated for this run that the page never sees, forwarding the
# page's RPC and declining after a pause; `qa-wallet` reading the address and
# balances from a fake RPC; `waitForReceipt` against it; and a recorded video
# transcoded to H.264. Then the evidence tools and the shared session
# (`qa-check-tools.js`): the static lead-in trim, the contact sheet, the
# qa-node deadline, a saved login written back on close, stop, SIGTERM
# and SIGINT, the expectState wait cap, one browser shared by separate
# probe processes and started on a slow first load, `expectState` and
# redaction.
# Linux only: the Darwin sandbox cannot launch Chromium. The sandbox has no
# /etc/fonts, and Chromium without a font gives an element holding only text
# an empty box, which Playwright reports as hidden; the check gets DejaVu, as
# a host has its own fonts.
{ pkgs }:

let
  playwright = import ./. { inherit pkgs; };
in
pkgs.runCommand "qa-check"
  {
    nativeBuildInputs = [ playwright.qa ];
    FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts.minimal ]; };
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME" "$TMPDIR/work"
    cd "$TMPDIR/work"
    # The build bounds the run; the deadline is tested inside it.
    export QA_NODE_TIMEOUT=0
    qa-node ${./qa-check.js} "$TMPDIR/work"
    qa-node ${./qa-check-tools.js} "$TMPDIR/work"
    touch "$out"
  ''
