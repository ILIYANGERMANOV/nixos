{
  root,
  pkgs,
  lib,
  osConfig,
  ...
}:
let
  # Read only on darwin, the one platform that declares the option.
  touchSound = import "${root}/programs/yubikey-touch-sound" {
    inherit pkgs lib;
    inherit (osConfig.myConfig.yubikey) noTouchSigning;
  };
  tempFactory = import "${root}/programs/temp-factory" {
    inherit pkgs;
    touchSsh = lib.getExe touchSound.ssh;
  };
in
{
  # macOS only: it needs Apple's caffeinate and pmset.
  home.packages = lib.mkIf pkgs.stdenv.isDarwin [ tempFactory.cli ];
}
