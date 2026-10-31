# The optional shellcheck rules every script here is held to, in one place: the
# `shell-lint` tech check and each writeShellApplication read them from here, so
# the fragments and the assembled scripts cannot disagree. Not `--enable=all`:
# its bulk is style (SC2250, SC2292) rather than bugs.
{ pkgs }:

let
  extraFlags = [
    "--enable=check-set-e-suppressed,check-extra-masked-returns,add-default-case,deprecate-which,avoid-nullary-conditions"
  ];
in
{
  inherit extraFlags;

  writeShellApplication =
    args: pkgs.writeShellApplication (args // { extraShellCheckFlags = extraFlags; });
}
