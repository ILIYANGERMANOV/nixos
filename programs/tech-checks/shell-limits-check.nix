# Fixture for the Nix limit in `shell-limits`, never built. Each sink has a
# string at the limit and one over it, and the strings under `free` are over it
# in places the check must not measure. `nixFiles` in shell.nix keeps this file,
# and only this file, out of the real scan.
{
  pkgs,
  lib,
  launcher,
  ...
}:
{
  sinks = {
    at = {
      script = pkgs.writeShellScript "x" ''
        echo 1
        echo 2
        echo 3
        echo 4
        echo 5
      '';
      scriptBin = pkgs.writeScriptBin "x" ''
        echo 1
        echo 2
        echo 3
        echo 4
        echo 5
      '';
      launcher = launcher "x" ''
        echo 1
        echo 2
        echo 3
        echo 4
        echo 5
      '';
      dag = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        echo 1
        echo 2
        echo 3
        echo 4
        echo 5
      '';
      application = pkgs.writeShellApplication {
        name = "x";
        text = ''
          echo 1
          echo 2
          echo 3
          echo 4
          echo 5
        '';
      };
      unit.script = ''
        echo 1
        echo 2
        echo 3
        echo 4
        echo 5
      '';
      shell.shellHook = ''
        echo 1
        echo 2
        echo 3
        echo 4
        echo 5
      '';
      serviceConfig.ExecStart = ''
        echo 1
        echo 2
        echo 3
        echo 4
        echo 5
      '';
      drv.installPhase = ''
        echo 1
        echo 2
        echo 3
        echo 4
        echo 5
      '';
      drv.postInstall = ''
        echo 1
        echo 2
        echo 3
        echo 4
        echo 5
      '';
      home.activation.link = ''
        echo 1
        echo 2
        echo 3
        echo 4
        echo 5
      '';
      system.activationScripts.link = ''
        echo 1
        echo 2
        echo 3
        echo 4
        echo 5
      '';
    };
    over = {
      script = pkgs.writeShellScript "x" ''
        echo 1
        echo 2
        echo 3
        echo 4
        echo 5
        echo 6
      '';
      scriptBin = pkgs.writeScriptBin "x" ''
        echo 1
        echo 2
        echo 3
        echo 4
        echo 5
        echo 6
      '';
      launcher = launcher "x" ''
        echo 1
        echo 2
        echo 3
        echo 4
        echo 5
        echo 6
      '';
      dag = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        echo 1
        echo 2
        echo 3
        echo 4
        echo 5
        echo 6
      '';
      application = pkgs.writeShellApplication {
        name = "x";
        text = ''
          echo 1
          echo 2
          echo 3
          echo 4
          echo 5
          echo 6
        '';
      };
      unit.script = ''
        echo 1
        echo 2
        echo 3
        echo 4
        echo 5
        echo 6
      '';
      shell.shellHook = ''
        echo 1
        echo 2
        echo 3
        echo 4
        echo 5
        echo 6
      '';
      serviceConfig.ExecStart = ''
        echo 1
        echo 2
        echo 3
        echo 4
        echo 5
        echo 6
      '';
      drv.installPhase = ''
        echo 1
        echo 2
        echo 3
        echo 4
        echo 5
        echo 6
      '';
      drv.postInstall = ''
        echo 1
        echo 2
        echo 3
        echo 4
        echo 5
        echo 6
      '';
      home.activation.link = ''
        echo 1
        echo 2
        echo 3
        echo 4
        echo 5
        echo 6
      '';
      system.activationScripts.link = ''
        echo 1
        echo 2
        echo 3
        echo 4
        echo 5
        echo 6
      '';
    };
  };

  free = {
    home.initContent = ''
      echo 1
      echo 2
      echo 3
      echo 4
      echo 5
      echo 6
    '';
    file = pkgs.writeText "x" ''
      echo 1
      echo 2
      echo 3
      echo 4
      echo 5
      echo 6
    '';
    script = pkgs.writeText "x.lua" ''
      echo 1
      echo 2
      echo 3
      echo 4
      echo 5
      echo 6
    '';
    nvim.extraConfigLua = ''
      echo 1
      echo 2
      echo 3
      echo 4
      echo 5
      echo 6
    '';
    settings = pkgs.writeTextFile {
      name = "x";
      text = ''
        echo 1
        echo 2
        echo 3
        echo 4
        echo 5
        echo 6
      '';
    };
  };
}
