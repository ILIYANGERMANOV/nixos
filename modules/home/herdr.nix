{
  inputs,
  pkgs,
  themeConfig,
  ...
}:
let
  # The vendored libghostty-vt build execs hardcoded host tools (/bin/cp,
  # /bin/ln, /usr/bin/ranlib, /usr/bin/xcrun) that the Darwin Nix sandbox
  # refuses, so resolve them from PATH instead. Copied from nixpkgs 46b9b90f42
  # (pkgs/by-name/he/herdr/package.nix). Drop this and use pkgs.herdr once the
  # pinned nixpkgs release carries herdr (26.11) or upstream herdr fixes it.
  # Darwin only, so the Linux drv stays upstream's.
  herdrUpstream = inputs.herdr.packages.${pkgs.stdenv.hostPlatform.system}.default;
  herdr =
    if pkgs.stdenv.hostPlatform.isDarwin then
      herdrUpstream.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace vendor/libghostty-vt/pkg/apple-sdk/native_link.zig \
            --replace-fail '"/usr/bin/xcrun"' '"xcrun"'
          substituteInPlace vendor/libghostty-vt/src/build/GhosttyLibVt.zig \
            --replace-fail '"/bin/ln"' '"ln"'
          substituteInPlace vendor/libghostty-vt/src/build/LibtoolStep.zig \
            --replace-fail '/bin/cp ' 'cp ' \
            --replace-fail '/usr/bin/ranlib ' 'ranlib '
        '';
      })
    else
      herdrUpstream;

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
    # Skip the first-run onboarding wizard; everything it asks is set here.
    onboarding = false;
    theme = themeSettings;
    keys = {
      # ctrl+b is Claude Code's "background this command"; ctrl+x only shadows
      # things with an easy escape hatch (press it twice to send it through).
      prefix = "ctrl+x";

      # Jump straight to a sidebar agent by position: prefix, then alt+N.
      # "1..9" is herdr's only range token, and alt is what keeps the bare
      # prefix+1..9 digits on switch_tab — a user binding silently wins over a
      # default one, so without alt this would take tab switching away.
      # Positions follow the sidebar (workspace, then tab, then pane) and skip
      # panes with no agent, so they stay put as long as the layout does.
      focus_agent = "prefix+alt+1..9";
    };
  };
in
{
  home.packages = [ herdr ];

  # herdr reads ~/.config/herdr/config.toml on both Linux and macOS
  xdg.configFile."herdr/config.toml".source = configFile;
}
