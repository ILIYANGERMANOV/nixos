# shellcheck shell=bash
substituteInPlace vendor/libghostty-vt/pkg/apple-sdk/native_link.zig \
  --replace-fail '"/usr/bin/xcrun"' '"xcrun"'
substituteInPlace vendor/libghostty-vt/src/build/GhosttyLibVt.zig \
  --replace-fail '"/bin/ln"' '"ln"'
substituteInPlace vendor/libghostty-vt/src/build/LibtoolStep.zig \
  --replace-fail '/bin/cp ' 'cp ' \
  --replace-fail '/usr/bin/ranlib ' 'ranlib '
