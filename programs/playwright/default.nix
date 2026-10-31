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
      hash = "sha256-Vh1yscy6wQf5rzib+NLlzDQYmgepz8KBsrpwupULqCA=";
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
      runHook preInstall
      modules="$out/lib/node_modules"
      mkdir -p "$out/lib" "$check"
      mv node_modules "$modules"
      ln -s ${pkgs.playwright-test}/lib/node_modules/playwright "$modules/playwright"
      mv dist/kit "$modules/qa-kit"
      mv dist/wallet "$modules/qa-wallet"
      echo '{"type":"module"}' | tee "$modules/qa-kit/package.json" "$modules/qa-wallet/package.json" > "$check/package.json"
      mv dist/qa-check.js dist/qa-check-tools.js "$check/"
      ln -s "$modules" "$check/node_modules"
      runHook postInstall
    '';
  };
  modules = "${compiled}/lib/node_modules";

  qaWallet = pkgs.writeShellApplication {
    name = "qa-wallet";
    runtimeInputs = [ pkgs.nodejs ];
    text = ''exec node ${modules}/qa-wallet/cli.js "$@"'';
  };

  # A script that hangs still ends: QA_NODE_TIMEOUT (default 300 s, any
  # `timeout` duration, 0 for none) sends it SIGTERM, which lets qa-kit save
  # the login, then SIGKILL 10 s later; the exit status is 124.
  qaNode = pkgs.writeShellApplication {
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

  qaSession = pkgs.writeShellApplication {
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
  qaMp4 = pkgs.writeShellApplication {
    name = "qa-mp4";
    runtimeInputs = [ pkgs.ffmpeg-headless ];
    text = ''
      if [ "$#" -ne 2 ]; then
        echo "usage: qa-mp4 <in.webm> <out.mp4>" >&2
        exit 2
      fi
      offset=$(ffmpeg -hide_banner -nostats -i "$1" -map 0:v:0 -vf freezedetect=d=1 -f null - 2>&1 | awk '
        /freeze_start/ && !started { started = 1; start = $NF; next }
        /freeze_end/ && started && !ended { ended = 1; end = $NF }
        END { if (started && ended && start <= 1.5 && end > 0.5) printf "%.2f", end - 0.5; else print "0" }')
      ffmpeg -y -loglevel error -ss "$offset" -i "$1" \
        -vf 'scale=trunc(iw/2)*2:trunc(ih/2)*2' \
        -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$2"
      echo "qa-mp4: trimmed a ''${offset}s static lead-in; cite timestamps from $2"
    '';
  };

  # One contact sheet of labelled frames, three to a row at 480 px wide, so
  # checking a video costs one image read instead of one per timestamp.
  # Timestamps must be plain seconds: they are also the labels drawtext prints.
  # A time past the last frame is clamped to the last frame, labelled with
  # the video's length, so a timestamp cited a little long still gets a tile.
  qaFrames = pkgs.writeShellApplication {
    name = "qa-frames";
    runtimeInputs = [ pkgs.ffmpeg-headless ];
    text = ''
      if [ "$#" -ne 3 ]; then
        echo "usage: qa-frames <video> <t1,t2,...> <out.png>   (t in seconds, e.g. 3,7.5,12)" >&2
        exit 2
      fi
      video=$1 out=$3
      IFS=, read -ra times <<< "$2"
      label() {
        echo "drawtext=fontfile=${font}:text='$1':x=8:y=8:fontsize=22:fontcolor=white:box=1:boxcolor=black@0.7:boxborderw=6"
      }
      tmp=$(mktemp -d)
      trap 'rm -rf "$tmp"' EXIT
      n=0
      for t in "''${times[@]}"; do
        if ! [[ $t =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
          echo "qa-frames: '$t' is not a time in seconds" >&2
          exit 2
        fi
        frame=$(printf '%s/%03d.png' "$tmp" "$n")
        ffmpeg -y -loglevel error -ss "$t" -i "$video" -frames:v 1 -vf "scale=480:-2,$(label "$t s")" "$frame"
        if [ ! -s "$frame" ]; then
          end=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$video")
          end=$(printf '%.2f' "$end")
          echo "qa-frames: $t s is past the end of $video; using its last frame ($end s)" >&2
          # -update keeps overwriting one image, so what is left is the last frame.
          ffmpeg -y -loglevel error -sseof -1 -i "$video" -update 1 -vf "scale=480:-2,$(label "$end s (end)")" "$frame"
        fi
        if [ ! -s "$frame" ]; then
          echo "qa-frames: no frame in $video" >&2
          exit 1
        fi
        n=$((n + 1))
      done
      cols=$((n < 3 ? n : 3))
      rows=$(((n + cols - 1) / cols))
      ffmpeg -y -loglevel error -framerate 1 -i "$tmp/%03d.png" -vf "tile=''${cols}x''${rows}:padding=4:color=white" -frames:v 1 "$out"
      echo "qa-frames: $n tiles ($2 s) in $out"
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
