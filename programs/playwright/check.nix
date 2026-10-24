# checks.playwright: that the environment from `default.nix` is enough on its
# own. From an empty directory with nothing else set, node must resolve
# `require('playwright')` through NODE_PATH and find Chromium under
# PLAYWRIGHT_BROWSERS_PATH, and on Linux launch it headless and render a page.
{ pkgs }:

let
  playwright = import ./. { inherit pkgs; };
  inherit (pkgs) lib;

  script = pkgs.writeText "playwright-check.js" ''
    const fs = require('fs');
    const { chromium } = require('playwright');

    const executable = chromium.executablePath();
    if (!fs.existsSync(executable)) {
      throw new Error('chromium.executablePath() does not exist: ' + executable);
    }

    if (process.env.LAUNCH === '1') {
      (async () => {
        const browser = await chromium.launch();
        const page = await browser.newPage();
        await page.setContent('<p id="x">ok</p>');
        const text = await page.textContent('#x');
        await browser.close();
        if (text !== 'ok') throw new Error('unexpected page text: ' + text);
      })().catch((e) => { console.error(e); process.exit(1); });
    }
  '';
in
pkgs.runCommand "playwright-check"
  {
    nativeBuildInputs = [ pkgs.nodejs ];
    env = playwright.env // {
      LAUNCH = if pkgs.stdenv.isLinux then "1" else "0";
    };
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME" "$TMPDIR/empty"
    cd "$TMPDIR/empty"
    node ${script}
    touch "$out"
  ''
