{ root, config, ... }: {
  sops = {
    defaultSopsFile = "${root}/secrets/secrets.yaml";
    defaultSopsFormat = "yaml";
    age.keyFile = "/var/lib/sops-age/keys.txt";

    secrets.deslop-ultra-test-key = { owner = config.myConfig.user.name; };
    secrets.deslop-one-test-key   = { owner = config.myConfig.user.name; };
  };
}
