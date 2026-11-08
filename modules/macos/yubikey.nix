{ lib, ... }:
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
}
