# checks.self-improve: the /self-improve analyzer run on synthetic transcripts
# that test_self_improve.py writes in Claude Code's on-disk layout. Synthetic on
# purpose - this repository is public and real transcripts are private.
{ pkgs }:

pkgs.runCommand "self-improve-check" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python3 -I ${./test_self_improve.py} ${../custom/self-improve/scripts/analyze.py}
  touch $out
''
