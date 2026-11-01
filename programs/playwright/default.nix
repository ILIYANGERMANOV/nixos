# Playwright with its Chromium from nixpkgs, as the environment a process needs
# for `require('playwright')` to resolve from any directory and
# `chromium.launch()` to find a browser without downloading one. The node
# package and the browsers come from the same nixpkgs, so their revisions match.
#
# `qa` is the /qa skill's runtime: `qa-node`, a node that resolves
# `playwright`, `viem`, the `qa-wallet` helper and `qa-kit` (session attach,
# expectState, redacted capture) from any directory; `qa-session`, one
# long-lived browser the probes share; `qa-wallet` (the wallet's address and
# balances, derived from the key); `qa-mp4` and `qa-frames` for the evidence;
# plus ffmpeg and `timeout`. The environment lives in `qa-node` rather than
# the session, because an exported PLAYWRIGHT_BROWSERS_PATH would point a
# project's own, differently versioned Playwright at the wrong browsers.
{ pkgs }:
let
  shellCheck = import ../shell-check { inherit pkgs; };

  inherit (pkgs) lib;

  browsers = pkgs.playwright-driver.selectBrowsers {
    withFirefox = false;
    withWebkit = false;
  };

  env = {
    NODE_PATH = "${pkgs.playwright-test}/lib/node_modules";
    PLAYWRIGHT_BROWSERS_PATH = "${browsers}";
  };

  # The TypeScript sources and their locked dependencies, as a tech check needs
  # them. tsc and Biome come from nixpkgs, not the lock file: a `typescript` in
  # the lock file becomes viem's peer and ships in the runtime closure. Playwright
  # is a dev dependency for its types only, at the version of `playwright-test`.
  typescript = rec {
    fileset = lib.fileset.unions [
      ./package.json
      ./pnpm-lock.yaml
      ./tsconfig.json
      ./tsconfig.build.json
      (lib.fileset.fileFilter (file: file.hasExt "ts") ./.)
    ];
    src = lib.fileset.toSource {
      root = ./.;
      inherit fileset;
    };
    pnpmDeps = pkgs.fetchPnpmDeps {
      pname = "qa-tools";
      src = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.unions [
          ./package.json
          ./pnpm-lock.yaml
        ];
      };
      fetcherVersion = 4;
      hash = "sha256-Kb3qZkna1GFqEBGtpC5QepRhPoXSea6YhLY8j7soTqU=";
    };
    tsc = pkgs.typescript-go;
    # What a derivation needs to get `node_modules` from `pnpmDeps`.
    nativeBuildInputs = [
      pkgs.nodejs
      pkgs.pnpm
      pkgs.pnpmConfigHook
      pkgs.writableTmpDirAsHomeHook
    ];
  };

  # The compiled runtime. Node refuses type stripping under `node_modules`, and
  # `lib/node_modules` holds qa-kit, qa-wallet, viem and playwright side by side:
  # the packages are ES modules, which resolve siblings by directory and ignore
  # NODE_PATH, while a script's `require` finds them through it. `check` is the
  # compiled checks.qa scripts, kept out of the runtime.
  compiled = pkgs.stdenvNoCC.mkDerivation {
    pname = "qa-tools";
    version = "1.0.0";
    outputs = [
      "out"
      "check"
    ];
    inherit (typescript) src pnpmDeps;
    nativeBuildInputs = typescript.nativeBuildInputs ++ [ typescript.tsc ];
    buildPhase = ''
      runHook preBuild
      tsgo -p tsconfig.build.json
      pnpm prune --prod --ignore-scripts
      runHook postBuild
    '';
    installPhase = ''
      ${lib.toShellVars { playwright = "${pkgs.playwright-test}/lib/node_modules/playwright"; }}
      ${shellCheck.fragment ./install-compiled.sh}
    '';
  };
  modules = "${compiled}/lib/node_modules";

  qaWallet = shellCheck.writeShellApplication {
    name = "qa-wallet";
    runtimeInputs = [ pkgs.nodejs ];
    text = ''exec node ${modules}/qa-wallet/cli.js "$@"'';
  };

  # A script that hangs still ends: QA_NODE_TIMEOUT (default 300 s, any
  # `timeout` duration, 0 for none) sends it SIGTERM, which lets qa-kit save
  # the login, then SIGKILL 10 s later; the exit status is 124.
  qaNode = shellCheck.writeShellApplication {
    name = "qa-node";
    runtimeInputs = [
      pkgs.nodejs
      timeout
    ];
    text = ''
      export NODE_PATH="${env.NODE_PATH}:${modules}"
      export PLAYWRIGHT_BROWSERS_PATH="${env.PLAYWRIGHT_BROWSERS_PATH}"
      export QA_WALLET_MODULE="${modules}/qa-wallet/index.js"
      exec timeout --kill-after=10 "''${QA_NODE_TIMEOUT:-300}" node "$@"
    '';
  };

  qaSession = shellCheck.writeShellApplication {
    name = "qa-session";
    runtimeInputs = [ qaNode ];
    text = ''exec qa-node ${modules}/qa-kit/session.js "$@"'';
  };

  # Playwright records webm from context creation, so a video opens on
  # whatever static screen the script waited on first. A freeze that starts
  # within 1.5 s of the start is cut down to its last 0.5 s; a later freeze is
  # the app being slow and stays. GitHub plays H.264 mp4 inline. libx264 with
  # yuv420p needs even dimensions, and faststart lets the video play before
  # it has fully downloaded.
  qaMp4 = shellCheck.writeShellApplication {
    name = "qa-mp4";
    runtimeInputs = [ pkgs.ffmpeg-headless ];
    text = shellCheck.fragment ./qa-mp4.sh;
  };

  # One contact sheet of labelled frames, three to a row at 480 px wide, so
  # checking a video costs one image read instead of one per timestamp.
  # Timestamps must be plain seconds: they are also the labels drawtext prints.
  # A time past the last frame is clamped to the last frame, labelled with
  # the video's length, so a timestamp cited a little long still gets a tile.
  qaFrames = shellCheck.writeShellApplication {
    name = "qa-frames";
    runtimeInputs = [ pkgs.ffmpeg-headless ];
    text = ''
      ${lib.toShellVars { inherit font; }}
      ${shellCheck.fragment ./qa-frames.sh}
    '';
  };
  font = "${pkgs.dejavu_fonts.minimal}/share/fonts/truetype/DejaVuSans.ttf";

  # Only `timeout` from coreutils: a scenario runs in the foreground under it,
  # and macOS has none, while all of coreutils would shadow the BSD tools.
  timeout = pkgs.runCommand "qa-timeout" { } ''
    mkdir -p "$out/bin"
    ln -s ${pkgs.coreutils}/bin/timeout "$out/bin/timeout"
  '';
in
{
  inherit env typescript;

  # The compiled scripts checks.qa runs under `qa-node`.
  qaCheckScripts = compiled.check;

  qa = pkgs.symlinkJoin {
    name = "qa-runtime";
    paths = [
      qaNode
      qaSession
      qaMp4
      qaFrames
      qaWallet
      timeout
      pkgs.ffmpeg-headless
    ];
  };
}
