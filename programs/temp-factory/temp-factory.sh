# shellcheck shell=bash disable=SC2154 # touch_ssh is set by another fragment
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
case "$(pmset -g batt)" in
  *"'Battery Power'"*)
    echo "temp-factory: warning: on battery power. This run will drain the battery, and caffeinate -s only keeps the Mac awake on AC power. Plug in for a long run." >&2
    ;;
  *) ;;
esac

# Warm the ControlMaster now, while the user is at the YubiKey: one tap covers
# the session's pushes (ControlPersist, modules/home/ssh.nix). GitHub gives no
# shell, so ssh exits 1 on success and on a refused key alike: only its
# greeting tells them apart. Capturing puts stderr on a pipe, where plain ssh
# prints no touch prompt and seems to hang; touch_ssh shows it through
# SSH_ASKPASS, only when a tap is needed, and shares the ControlMaster. The
# loop echoes each line to our own stderr as it arrives, so the prompt shows
# while ssh waits. Not `tee /dev/stderr`: on Linux that reopens the file behind
# fd 2 and truncates it, erasing what was already written there.
ssh_output=""
while IFS= read -r line || [[ -n $line ]]; do
  printf '%s\n' "$line" >&2
  ssh_output+="$line"$'\n'
done < <("$touch_ssh" -T git@github.com 2>&1 || true)
case "$ssh_output" in
  *"successfully authenticated"*) ;;
  *)
    echo "temp-factory: GitHub did not confirm the ssh login. Plug in your YubiKey and tap it when asked, then retry." >&2
    exit 1
    ;;
esac

cd "$toplevel" || exit
# exec keeps caffeinate and claude in the terminal's foreground process group,
# so Ctrl-C reaches both and the sleep assertion dies with them. -i -s blocks
# idle and (on AC) system sleep only: never -d, so the display still sleeps
# and locks, and a closed lid still sleeps.
exec caffeinate -i -s claude-all remote-control \
  --name "${toplevel##*/}" \
  --spawn worktree \
  --capacity "$capacity" \
  --no-create-session-in-dir \
  --permission-mode auto
