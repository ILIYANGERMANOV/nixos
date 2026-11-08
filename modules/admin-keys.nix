# The admin's keys: macos-main's YubiKey-backed keys, primary and backup. They
# belong to the person, not to any one server, so lib.mkNixosServer adds this
# to every server, whatever it runs.
{
  myConfig.admin.authorizedKeys = [
    "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIE7xT+rb5Xcz31HAjh0peMajLeY1CBdI/0dYAj1zrrB6AAAADnNzaDptYWNvcy1tYWlu"
    "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIKrxuyp7hrI5IKNj7wltctEH6L7EUqqbgr/ePF/OYjy7AAAADnNzaDptYWNvcy1tYWlu"
  ];
}
