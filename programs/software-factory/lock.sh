# shellcheck shell=bash
# Serialises the launchers and the skill relink, on this lock held on fd 9.
open_factory_lock() {
  mkdir -p "$HOME/.claude"
  exec 9>"$HOME/.claude/.factory.lock"
}
