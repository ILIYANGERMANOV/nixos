# `just probe-agents-hooks`: probe.py against the pinned Claude Code, so a bump
# PR probes the version it pins before anyone installs it. A runner and never
# a flake check: the client needs a writable home and a loopback port, and a
# check would run in `just tech`, `just quick-check` and `nix flake check`.
{ pkgs, claude-code }:
let
  inherit (pkgs) lib;
  shellCheck = import ../../../shell-check { inherit pkgs; };

  # probe.py imports the modules beside it, and so do the hooks it registers.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./probe.py
      ./client.py
      ./live.py
      ./model.py
    ];
  };
in
shellCheck.writeShellApplication {
  name = "probe-agents-hooks";
  runtimeInputs = [ claude-code ];
  text = ''exec ${lib.getExe pkgs.python3} ${src}/probe.py "$@"'';
}
