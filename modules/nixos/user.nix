{
  config,
  lib,
  root,
  ...
}:
let
  cfg = config.myConfig.user;
in
{
  options.myConfig.user = {
    name = lib.mkOption {
      type = lib.types.str;
      description = "Primary user's login name";
    };
    fullName = lib.mkOption {
      type = lib.types.str;
      description = "Primary user's full name";
    };
    email = lib.mkOption {
      type = lib.types.str;
      description = "Primary user's email address";
    };
    extraGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "wheel"
        "networkmanager"
        "video"
        "audio"
      ];
      description = "Groups the user belongs to";
    };
  };

  config = {
    sops.secrets."${cfg.name}-password" = {
      neededForUsers = true;
    };

    users.mutableUsers = false;
    users.users.${cfg.name} = {
      isNormalUser = true;
      description = cfg.fullName;
      inherit (cfg) extraGroups;
      hashedPasswordFile = config.sops.secrets."${cfg.name}-password".path;
    };

    home-manager.users.${cfg.name} = import "${root}/modules/home/default.nix";
  };
}
