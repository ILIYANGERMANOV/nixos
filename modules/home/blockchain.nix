{ pkgs, ... }:
{
  home.packages = with pkgs; [
    # forge, cast, anvil and chisel - build/test, chain RPC, local devnet, REPL.
    foundry
    # Standalone solc. Foundry resolves its own compiler through svm, which
    # downloads into ~/.svm at build time; this one is the offline fallback and
    # what non-foundry tooling (slither, editors, scripts) compiles with.
    solc
    # Static analysis for Solidity. Brings solc-select along for pinning the
    # compiler version a contract expects.
    slither-analyzer
  ];
}
