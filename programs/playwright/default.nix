# Playwright with its Chromium from nixpkgs, as the environment a process needs
# for `require('playwright')` to resolve from any directory and
# `chromium.launch()` to find a browser without downloading one. The node
# package and the browsers come from the same nixpkgs, so their revisions match.
#
# `qa` is the /qa skill's runtime: `qa-node`, a node that resolves
# `playwright`, `viem` and the `qa-wallet` helper from any directory, the
# `qa-wallet` command (the wallet's address and balances, derived from the
# key), plus ffmpeg for webm -> mp4. The environment lives in `qa-node` rather than the
# session, because an exported PLAYWRIGHT_BROWSERS_PATH would point a
# project's own, differently versioned Playwright at the wrong browsers.
{ pkgs }:
let
  inherit (pkgs) lib;

  browsers = pkgs.playwright-driver.selectBrowsers {
    withFirefox = false;
    withWebkit = false;
  };

  env = {
    NODE_PATH = "${pkgs.playwright-test}/lib/node_modules";
    PLAYWRIGHT_BROWSERS_PATH = "${browsers}";
  };

  # The wallet helper with viem as its own dependency, pinned by the lock file.
  wallet = pkgs.buildNpmPackage {
    pname = "qa-wallet";
    version = "1.0.0";
    src = lib.fileset.toSource {
      root = ./wallet;
      fileset = lib.fileset.unions [
        ./wallet/package.json
        ./wallet/package-lock.json
        ./wallet/index.js
        ./wallet/cli.js
      ];
    };
    npmDepsHash = "sha256-52Ye5hQDGtMYcXxPic8agTIEfVyCm9Hl4FkBC+9Pr7M=";
    dontNpmBuild = true;
  };
  walletModules = "${wallet}/lib/node_modules";

  qaNode = pkgs.writeShellApplication {
    name = "qa-node";
    runtimeInputs = [ pkgs.nodejs ];
    text = ''
      export NODE_PATH="${env.NODE_PATH}:${walletModules}:${walletModules}/qa-wallet/node_modules"
      export PLAYWRIGHT_BROWSERS_PATH="${env.PLAYWRIGHT_BROWSERS_PATH}"
      export QA_WALLET_MODULE="${walletModules}/qa-wallet/index.js"
      exec node "$@"
    '';
  };

  # Playwright records webm; GitHub plays H.264 mp4 inline. libx264 with
  # yuv420p needs even dimensions, and faststart lets the video play before
  # it has fully downloaded.
  qaMp4 = pkgs.writeShellApplication {
    name = "qa-mp4";
    runtimeInputs = [ pkgs.ffmpeg-headless ];
    text = ''
      if [ "$#" -ne 2 ]; then
        echo "usage: qa-mp4 <in.webm> <out.mp4>" >&2
        exit 2
      fi
      ffmpeg -y -loglevel error -i "$1" \
        -vf 'scale=trunc(iw/2)*2:trunc(ih/2)*2' \
        -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$2"
    '';
  };
in
{
  inherit env;

  qa = pkgs.symlinkJoin {
    name = "qa-runtime";
    paths = [
      qaNode
      qaMp4
      wallet
      pkgs.ffmpeg-headless
    ];
  };
}
