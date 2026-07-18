{ root, ... }: {
  sops = {
    defaultSopsFile = "${root}/secrets/secrets.yaml";
    defaultSopsFormat = "yaml";
    age.keyFile = "/var/lib/sops-age/keys.txt";
  };
}
