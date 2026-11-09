# shellcheck shell=bash
# Serve one repo to the Claude phone app through Remote Control, in the
# foreground, until Ctrl-C. Each phone session gets its own git worktree.

usage() {
  echo "usage: temp-factory [--capacity N] [dir]" >&2
  exit 2
}

capacity=4
dir=$PWD
dir_given=0
while (($# > 0)); do
  case "$1" in
    --capacity)
      [[ ${2-} =~ ^[1-9][0-9]*$ ]] || usage
      capacity=$2
      shift 2
      ;;
    -*) usage ;;
    *)
      ((dir_given == 0)) || usage
      dir=$1
      dir_given=1
      shift
      ;;
  esac
done

# Worktree spawning needs a repo, and its root names the server.
if ! toplevel=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null); then
  echo "temp-factory: $dir is not inside a git repository" >&2
  exit 1
fi

# A read only: no power setting is ever written.
power=$(pmset -g batt)
case "$power" in
  *"'Battery Power'"*)
    echo "temp-factory: warning: on battery. This keeps the Mac awake and drains the battery; plug in for a long run." >&2
    ;;
  *) ;;
esac

# Warm the ControlMaster now, while the user is at the YubiKey: one tap covers
# the session's pushes (ControlPersist, modules/home/ssh.nix). GitHub answers a
# good login with exit 1, as it gives no shell.
ssh_status=0
ssh -T git@github.com || ssh_status=$?
case "$ssh_status" in
  1) ;;
  *)
    echo "temp-factory: ssh to GitHub failed (exit $ssh_status). Plug in the YubiKey and tap it when asked, then retry." >&2
    exit 1
    ;;
esac

cd "$toplevel" || exit
# exec keeps caffeinate and claude in the terminal's foreground process group,
# so Ctrl-C reaches both and the sleep assertion dies with them. -i -s blocks
# idle and (on AC) system sleep only: never -d, so the display still sleeps
# and locks, and a closed lid still sleeps.
exec caffeinate -i -s claude-pm remote-control \
  --name "${toplevel##*/}" \
  --spawn worktree \
  --capacity "$capacity" \
  --no-create-session-in-dir \
  --permission-mode auto
