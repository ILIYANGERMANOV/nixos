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
  inherit (import "${root}/programs/playwright" { inherit pkgs; }) qa;
  externalSrcs.mattpocock = inputs.mattpocock-skills;
}
