{
  root,
  pkgs,
  inputs,
  lib ? pkgs.lib,
}:

import "${root}/programs/skills" {
  inherit pkgs lib;
  externalSrcs.mattpocock = inputs.mattpocock-skills;
}
