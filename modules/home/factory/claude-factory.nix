# One Remote Control server per repository in ~/repos, as instances of the
# claude-rc@ user unit, plus the boot unit that clones the declared repositories
# and starts them all.
{
  root,
  inputs,
  pkgs,
  lib,
  config,
  osConfig,
  themeConfig,
  secretsConfig,
  ...
}:

let
  claude = import "${root}/lib/claude-code.nix" {
    inherit
      root
      pkgs
      inputs
      lib
      ;
    theme = themeConfig;
    secrets = secretsConfig;
  };
  factory = import "${root}/programs/software-factory" { inherit pkgs lib; };

  remoteControl = factory.mkRemoteControl {
    claude = claude.factory.wrapper;
    claudeUnwrapped = claude.factory.unwrapped;
    ghToken =
      secretsConfig.gh-token
        or (throw "software-factory: the host must declare myConfig.secrets.gh-token for gh");
  };

  # A systemd unit's PATH holds only systemd's own directories. Agents need
  # this account's profile and the system's, including setuid wrappers.
  path = lib.concatStringsSep ":" [
    "/etc/profiles/per-user/${config.home.username}/bin"
    "/run/wrappers/bin"
    "/run/current-system/sw/bin"
  ];
in
{
  home.packages = [
    claude.factory.wrapper
    factory.factoryAdd
  ];

  systemd.user.services = {
    "claude-rc@" = {
      Unit.Description = "Claude Code Remote Control for ~/repos/%i";
      Service = {
        ExecStart = "${lib.getExe remoteControl} %i";
        Environment = [ "PATH=${path}" ];
        # Belt and braces with forceLoginMethod in the managed settings: nothing
        # may steer a session towards API billing or another endpoint.
        UnsetEnvironment = [
          "ANTHROPIC_API_KEY"
          "ANTHROPIC_AUTH_TOKEN"
          "ANTHROPIC_BASE_URL"
        ];
        Restart = "on-failure";
        RestartSec = 30;
      };
    };

    factory-repos = {
      Unit.Description = "Clone the declared repositories and start every Remote Control server";
      Service = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe (factory.mkStartAll osConfig.myConfig.factory.repos);
        Environment = [ "PATH=${path}" ];
        # A clone fails until the bot's key exists and the network is up.
        Restart = "on-failure";
        RestartSec = 60;
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
