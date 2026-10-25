# Playwright with its Chromium from nixpkgs, as the environment a process needs
# for `require('playwright')` to resolve from any directory and
# `chromium.launch()` to find a browser without downloading one. The node
# package and the browsers come from the same nixpkgs, so their revisions match.
{ pkgs }:
let
  browsers = pkgs.playwright-driver.selectBrowsers {
    withFirefox = false;
    withWebkit = false;
  };
in
{
  env = {
    NODE_PATH = "${pkgs.playwright-test}/lib/node_modules";
    PLAYWRIGHT_BROWSERS_PATH = "${browsers}";
  };
}
