# `temp-factory [--capacity N] [dir]`: Remote Control from a Mac repo, steered
# from the Claude phone app, until Ctrl-C. macOS only: it calls Apple's
# caffeinate and pmset, and the host's `claude-pm` flavor from PATH.
{
  pkgs,
  # The ssh that shows (and sounds) the YubiKey touch prompt with stderr on a
  # pipe: `yubikey-touch-ssh` from programs/yubikey-touch-sound.
  touchSsh,
}:

let
  shellCheck = import ../shell-check { inherit pkgs; };
in
{
  cli = shellCheck.writeShellApplication {
    name = "temp-factory";
    text = ''
      ${pkgs.lib.toShellVars { touch_ssh = touchSsh; }}
      ${shellCheck.fragment ./temp-factory.sh}
    '';
  };
}
