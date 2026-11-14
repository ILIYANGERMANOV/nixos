# The Haskell kernel in programs/agents/kernel, the repo's only Haskell. Its
# lint and runners come from programs/haskell through the agents' entry point.
{
  pkgs,
  kernel,
  kernelDev,
}:
{
  # The hspec suite runs in the package's checkPhase, so the package is the check.
  haskell-tests = kernel;

  # hlint, fourmolu and cabal-fmt, as `nix run .#kernel-lint` runs them. The
  # format half repeats `just format --ci`, so a miss shows in this job too.
  haskell-lint = kernelDev.lint;

  # The runners' shellcheck, which only building them runs.
  haskell-runners = pkgs.linkFarmFromDrvs "haskell-runners" kernelDev.scripts;
}
