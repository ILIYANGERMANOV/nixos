# shellcheck shell=bash disable=SC2154 # set by another fragment: the assembled script is checked whole
runHook preInstall
mkdir -p "$out/libexec" "$out/bin"
cp -r . "$out/libexec/kotlin-lsp"
# The launcher finds its jars and runtime relative to its own path, so
# it is wrapped, never symlinked. `intellij-server` is the name
# lspconfig's `kotlin_lsp` runs; `kotlin-lsp` the one people type.
makeWrapper "$out/libexec/kotlin-lsp/bin/intellij-server" "$out/bin/intellij-server"
ln -s intellij-server "$out/bin/kotlin-lsp"
runHook postInstall
