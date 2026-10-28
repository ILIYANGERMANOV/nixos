# One font for headless Chromium (the /qa runtime). With none, text renders
# as nothing and Playwright treats text-only elements as hidden. Fontconfig is
# already on; the Remote Control units read /etc/fonts like any process.
{ pkgs, ... }:
{
  fonts.packages = [ pkgs.dejavu_fonts ];
}
