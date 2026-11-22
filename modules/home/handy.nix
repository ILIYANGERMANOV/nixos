{
  root,
  pkgs,
  lib,
  config,
  ...
}:
let
  handy = import "${root}/programs/handy" { inherit pkgs; };
  appSupport = "Library/Application Support/com.pais.handy";
in
{
  # macOS only: the Handy app is a Homebrew cask there (modules/macos/common.nix).
  config = lib.mkIf pkgs.stdenv.isDarwin {
    home.file."${appSupport}/models/${handy.model.name}".source = handy.model;

    home.activation.handySettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${lib.getExe handy.apply} ${lib.escapeShellArg "${config.home.homeDirectory}/${appSupport}/settings_store.json"}
    '';
  };
}
