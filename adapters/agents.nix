{
  root,
  pkgs,
  inputs,
  lib ? pkgs.lib,
  # name -> decrypted-file path, for the secrets THIS host provides.
  secrets ? { },
}:

import "${root}/programs/agents" {
  inherit pkgs lib secrets;
  externalSrcs.mattpocock = inputs.mattpocock-skills;
}
