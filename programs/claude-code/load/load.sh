# shellcheck shell=bash disable=SC2154 # set by another fragment: the assembled script is checked whole
# Puts this flavor's runtime and secret file paths in the environment and execs Claude Code.

# A secret file goes out as its path, never its value: the program that needs
# it reads the file itself.
export PATH="$runtime_path:$PATH"
for var in "${!secret_files[@]}"; do
  export "$var=${secret_files[$var]}"
done
exec "$claude_bin" "$@"
