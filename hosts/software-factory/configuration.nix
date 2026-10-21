{ lib, ... }:
{
  imports = [ ./disk-config.nix ];

  networking.hostName = "software-factory";

  myConfig = {
    # The agent account commits as the bot, which has write access to the
    # repositories but cannot merge into their protected main branches.
    user = {
      name = "factory";
      fullName = "IvyBot";
      email = "93778811+ivywallet@users.noreply.github.com";
    };

    # macos-main's YubiKey-backed keys, primary and backup.
    admin.authorizedKeys = [
      "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIE7xT+rb5Xcz31HAjh0peMajLeY1CBdI/0dYAj1zrrB6AAAADnNzaDptYWNvcy1tYWlu"
      "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIKrxuyp7hrI5IKNj7wltctEH6L7EUqqbgr/ePF/OYjy7AAAADnNzaDptYWNvcy1tYWlu"
    ];

    # Public repositories only - private ones are added on the box with
    # factory-add and never named here.
    factory.repos = {
      nixos = "git@github.com:ILIYANGERMANOV/nixos.git";
      deslop = "git@github.com:Ivy-Apps/deslop.git";
      haskell-template = "git@github.com:Ivy-Apps/haskell-template.git";
    };

    secrets = {
      gh-token = { };

      # modules/secrets.nix declares this probe as global on every host. This
      # host's age key is not a recipient of secrets/common.yaml, so the probe
      # reads the same key from the host's own file instead.
      example-global.scope = lib.mkForce "host";
    };
  };

  system.stateVersion = "26.05";
}
