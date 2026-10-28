# checks.qa: the /qa runtime headless, with nothing but `qa-node` and
# `qa-mp4` on PATH - the wallet helper discovered through EIP-6963, connected,
# signing with a key generated for this run that the page never sees, and a
# recorded video transcoded to H.264. Linux only: the Darwin sandbox cannot
# launch Chromium.
{ pkgs }:

let
  playwright = import ./. { inherit pkgs; };
in
pkgs.runCommand "qa-check" { nativeBuildInputs = [ playwright.qa ]; } ''
  export HOME="$TMPDIR/home"
  mkdir -p "$HOME" "$TMPDIR/work"
  cd "$TMPDIR/work"
  qa-node ${./qa-check.js} "$TMPDIR/work"
  touch "$out"
''
