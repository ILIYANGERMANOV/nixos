# What every software factory shares: the bot it commits as, the repository
# it deploys from and the repositories it serves. Set at normal priority, so a
# host adds a repository with `myConfig.factory.repos.<name> = "..."`, and
# replaces the list or a scalar with `lib.mkForce`.
{ lib, ... }:
{
  myConfig = {
    # The agent account commits as the bot, which has write access to the
    # repositories but cannot merge into their protected main branches.
    user = {
      name = "factory";
      fullName = "IvyBot";
      email = "93778811+ivywallet@users.noreply.github.com";
    };

    factory = {
      # Deploys are pulled from this repository (./ops.nix).
      deploy.repo = "ILIYANGERMANOV/nixos";

      # Public repositories only - private ones are added on the box with
      # `factory-ctl start` and never named here.
      repos = {
        nixos = "git@github.com:ILIYANGERMANOV/nixos.git";
        deslop = "git@github.com:Ivy-Apps/deslop.git";
        haskell-template = "git@github.com:Ivy-Apps/haskell-template.git";
      };
    };

    secrets = {
      # The bot's token, one per box (modules/home/factory/claude-factory.nix).
      gh-token = { };

      # modules/secrets.nix declares this probe as global on every host. A
      # factory's age key is not a recipient of secrets/common.yaml, so the
      # probe reads the same key from the host's own file instead.
      example-global.scope = lib.mkForce "host";
    };
  };
}
