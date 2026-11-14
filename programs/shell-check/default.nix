# The optional shellcheck rules every script here is held to, in one place: the
# `shell-lint` and `shell-just` tech checks and each writeShellApplication read
# them from here, so no two can disagree. Not `--enable=all`:
# its bulk is style (SC2250, SC2292) rather than bugs.
{ pkgs }:

let
  inherit (pkgs) lib;

  extraFlags = [
    "--enable=check-set-e-suppressed,check-extra-masked-returns,add-default-case,deprecate-which,avoid-nullary-conditions"
  ];
in
{
  inherit extraFlags;

  writeShellApplication =
    args: pkgs.writeShellApplication (args // { extraShellCheckFlags = extraFlags; });

  # The same script with only bash's syntax check, for one an agent waits on
  # `nix run` to evaluate: shellcheck is Haskell, so its phase costs about 2s
  # of evaluation on every run. `passthru.checked` is the script shellchecked,
  # which a check must build.
  writeQuickApplication =
    args:
    pkgs.writeShellApplication (
      args
      // {
        checkPhase = ''${pkgs.stdenv.shellDryRun} "$target"'';
        passthru.checked = pkgs.writeShellApplication (args // { extraShellCheckFlags = extraFlags; });
      }
    );

  # A fragment opens with a directive for the shell-lint check, which sees it
  # alone. Spliced mid-script that directive would silence only the function
  # below it, and for no reason: the assembled script defines everything.
  fragment =
    script:
    lib.concatLines (
      lib.filter (line: !lib.hasPrefix "# shellcheck shell=bash" line) (
        lib.splitString "\n" (builtins.readFile script)
      )
    );
}
