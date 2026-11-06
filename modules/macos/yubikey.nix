{
  lib,
  pkgs,
  config,
  ...
}:
let
  # The first release whose `ssh-keygen -p` takes `-O no-touch-required`.
  minOpenssh = "10.5p1";
in
{
  options.myConfig.yubikey.noTouchSigning = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Sign git commits with the YubiKey's SSH key without a tap. The key and
      its stub stay as they are: each sign clears the touch flag on a temp copy
      of the stub. SSH auth (push, ssh) keeps the tap. See docs/SSH.md.
    '';
  };

  config.assertions = [
    {
      assertion =
        !config.myConfig.yubikey.noTouchSigning || lib.versionAtLeast pkgs.openssh.version minOpenssh;
      message = "myConfig.yubikey.noTouchSigning needs OpenSSH >= ${minOpenssh}, got ${pkgs.openssh.version}.";
    }
  ];
}
