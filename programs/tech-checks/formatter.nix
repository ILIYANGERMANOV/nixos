# The single door behind `nix fmt` and `just format`: one treefmt, one entry per
# language, so `just format --ci` enforces them all.
{ pkgs }:
pkgs.treefmt.withConfig {
  runtimeInputs = [
    pkgs.nixfmt
    pkgs.biome
  ];
  settings = {
    # treefmt warns by default, too loud for a repo where most files have no formatter.
    on-unmatched = "info";
    formatter.nixfmt = {
      command = "nixfmt";
      includes = [ "*.nix" ];
    };
    formatter.biome = {
      command = "biome";
      options = [
        "format"
        "--write"
      ];
      includes = [
        "programs/playwright/*.ts"
        "programs/playwright/*.json"
        "programs/playwright/**/*.ts"
      ];
    };
  };
}
