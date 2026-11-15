# The dev tooling of a Haskell package in this repo, from one call: its dev
# shell, the runners agents use fastest first, and its lint check. Ported from
# Ivy-Apps/haskell-template's flake apps and nix/ghcid. How to use and add one:
# .claude/rules/haskell.md.
{ pkgs }:
let
  inherit (pkgs) lib;
  shellCheck = import ../shell-check { inherit pkgs; };
  hpkgs = pkgs.haskellPackages;

  # The formatters and linter: the runners, the lint check and treefmt share them.
  tools = {
    inherit (pkgs) hlint fourmolu;
    cabal-fmt = pkgs.haskell.lib.compose.justStaticExecutables hpkgs.cabal-fmt;
  };

  # A suite's environment as `export` lines: `env` verbatim, a path copied to
  # the store so a sandboxed check can read it, and each of `bins`
  # the path `binPath` gives the executable it names.
  exports =
    binPath:
    {
      env ? { },
      bins ? { },
    }:
    lib.concatLines (
      lib.mapAttrsToList (var: value: "export ${var}=${lib.escapeShellArg "${value}"}") env
      ++ lib.mapAttrsToList (var: exe: "export ${var}=${binPath exe}") bins
    );
in
{
  inherit tools;

  # For the package's own preCheck: Setup builds each executable under dist/.
  checkEnv = exports (exe: "$PWD/dist/build/${exe}/${exe}");

  # Every name it makes starts with `name`: the flake wires `shell` as
  # `devShells.<name>` and merges `apps`, `<name>-quick-typecheck` and the rest,
  # into its apps, since the quick runners spawn `nix develop .#<name>`.
  mkPackage =
    {
      name,
      # The Haskell derivation, before justStaticExecutables.
      package,
      # Its directory from the repository root.
      dir,
      testSuite,
      executables ? [ ],
      # What the suite reads from the environment: `env` the values, `bins` the
      # variables naming a built executable (see `exports`).
      testEnv ? { },
      testFlags ? [ ],
    }:
    let
      sourceDirs = [
        "app"
        "src"
        "test"
      ];

      # In a block, so one directive covers it: each script reads some.
      config = settings: ''
        # shellcheck disable=SC2034 # each script reads some
        {
        ${lib.toShellVars settings}
        }
      '';
      # The session's client reads nothing of `package`: that would evaluate
      # the GHC package set on every quick call. It globs the .cabal file.
      ghcidConfig = config {
        inherit name;
        package_dir = dir;
        source_dirs = sourceDirs;
        test_flags = testFlags;
        # An edit here changes the dev shell a session runs in: respawn it.
        respawn_on = [
          "flake.nix"
          "flake.lock"
          "${dir}/default.nix"
        ];
      };
      cabalConfig = config {
        cabal_file = "${package.pname}.cabal";
        source_dirs = sourceDirs;
        test_flags = testFlags;
        bins = testEnv.bins or { };
        # The test suite first: multi-unit GHCi evaluates an expression in the
        # first unit only, and quick-test's hook needs its `Main.spec`.
        components = [
          "${package.pname}:test:${testSuite}"
          "lib:${package.pname}"
        ]
        ++ map (exe: "${package.pname}:exe:${exe}") executables;
      };
      cabal = shellCheck.fragment ./cabal.sh;
      ghcid = shellCheck.fragment ./ghcid.sh;
      # A session spawned by other scripts or for other values is respawned.
      # The values include the suite's environment, so a session never runs
      # specs against a step table it no longer matches.
      version = builtins.hashString "sha256" (
        ghcidConfig + cabal + ghcid + builtins.toJSON (testEnv.env or { })
      );
      # The repl inherits these from the dev shell; the runners set them.
      cabalScript = cabalConfig + exports (_: "") { env = testEnv.env or { }; } + cabal;
      ghcidScript = ghcidConfig + config { inherit version; } + ghcid;

      # `<name>-<call>`, running the script's `run_<call>` in the
      # package directory, or where it is started when `enter` is false.
      script =
        {
          call,
          text,
          runtimeInputs,
          enter ? true,
          write ? shellCheck.writeShellApplication,
        }:
        write {
          name = "${name}-${call}";
          inherit runtimeInputs;
          text = lib.concatLines (
            [ text ]
            ++ lib.optionals enter [
              "root=$(git rev-parse --show-toplevel)"
              ''cd "$root"/${lib.escapeShellArg dir}''
            ]
            ++ [ ''run_${lib.replaceStrings [ "-" ] [ "_" ] call} "$@"'' ]
          );
        };
      cabalRunner =
        call:
        script {
          inherit call;
          text = cabalScript;
          runtimeInputs = [ pkgs.git ] ++ toolchain;
        };
      # Cheap to evaluate, since an agent waits on it: the toolchain comes
      # with the dev shell a session spawns in, and nix, git and pgrep (procps
      # pulls in systemd) are the caller's. GNU stat on Darwin too: the
      # freshness checks read `stat -c`.
      ghcidRuntime = [
        pkgs.coreutils
        pkgs.findutils
      ];
      ghcidRunner =
        call:
        script {
          inherit call;
          text = ghcidScript;
          runtimeInputs = ghcidRuntime ++ [ watchdog ];
          write = shellCheck.writeQuickApplication;
        };
      watchdog = script {
        call = "ghcid-watchdog";
        text = ghcidScript;
        runtimeInputs = ghcidRuntime;
        enter = false;
        write = shellCheck.writeQuickApplication;
      };
      # What the session runs `cabal repl` through, inside the dev shell.
      repl = script {
        call = "repl";
        text = cabalScript;
        runtimeInputs = [ ];
        enter = false;
      };

      shell = hpkgs.shellFor (
        {
          packages = _: [ package ];
          nativeBuildInputs = [
            pkgs.cabal-install
            pkgs.ghcid
            repl
          ]
          ++ lib.attrValues tools;
        }
        // (testEnv.env or { })
      );
      toolchain = shell.nativeBuildInputs;

      runners = {
        quick-typecheck = ghcidRunner "quick-typecheck";
        quick-test = ghcidRunner "quick-test";
        build = cabalRunner "build";
        test = cabalRunner "test";
        lint = cabalRunner "lint";
        format = cabalRunner "format";
      };
    in
    {
      inherit shell;
      apps = lib.mapAttrs' (call: drv: {
        name = "${name}-${call}";
        value = {
          type = "app";
          program = lib.getExe drv;
        };
      }) runners;
      # Every script it makes, so a check runs their shellcheck.
      scripts = map (drv: drv.checked or drv) (
        lib.attrValues runners
        ++ [
          watchdog
          repl
        ]
      );
      # The lint runner's checks over the package's source.
      lint = pkgs.runCommand "${name}-lint" { } ''
        cd ${package.src}
        ${lib.getExe (script {
          call = "lint";
          text = cabalScript;
          runtimeInputs = lib.attrValues tools;
          enter = false;
        })}
        touch "$out"
      '';
    };
}
