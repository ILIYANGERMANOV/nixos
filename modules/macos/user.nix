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
  };

  config = {
    system.primaryUser = cfg.name;
    users.users.${cfg.name} = {
      home = "/Users/${cfg.name}";
    };
    home-manager.users.${cfg.name} = import "${root}/modules/home/default.nix";
  };
}
