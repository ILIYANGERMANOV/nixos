{
  inputs,
  pkgs,
  themeConfig,
  ...
}:
let
  herdr = inputs.herdr.packages.${pkgs.stdenv.hostPlatform.system}.default;

  # Match Ghostty's TokyoNight look (see terminal.nix), keyed off the global
  # myConfig.theme switch so herdr blends into the terminal.
  themeSettings =
    {
      dark = {
        name = "tokyo-night";
      };
      light = {
        name = "tokyo-night-day";
      };
      auto = {
        name = "tokyo-night";
        auto_switch = true; # follow the host terminal's light/dark appearance
        dark_name = "tokyo-night";
        light_name = "tokyo-night-day";
      };
    }
    .${themeConfig};

  configFile = (pkgs.formats.toml { }).generate "herdr-config.toml" {
    theme = themeSettings;
  };
in
{
  home.packages = [ herdr ];

  # herdr reads ~/.config/herdr/config.toml on both Linux and macOS
  xdg.configFile."herdr/config.toml".source = configFile;
}
