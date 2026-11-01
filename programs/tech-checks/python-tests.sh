# shellcheck shell=bash disable=SC2154 # $out comes from the derivation
# A test imports bash_commands.py from source, so it gets what a guard gets.
cp -r "$PYTHON_SOURCE" source
chmod -R u+w source
cd source || exit 1
substituteInPlace programs/claude-code/bash_commands.py \
  --replace-fail @shfmt@ "$SHFMT"
HOME=$TMPDIR HYPOTHESIS_STORAGE_DIRECTORY=$TMPDIR/hypothesis PYTHONDONTWRITEBYTECODE=1 pytest
touch "$out"
