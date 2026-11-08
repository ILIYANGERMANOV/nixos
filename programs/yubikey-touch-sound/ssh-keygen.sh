# shellcheck shell=bash disable=SC2154 # set by another fragment: the assembled script is checked whole
signing=0
prev=""
for arg in "$@"; do
  if [ "$prev" = "-Y" ] && [ "$arg" = "sign" ]; then
    signing=1
    break
  fi
  prev="$arg"
done

if [ "$signing" -eq 0 ]; then
  exec "$openssh_keygen" "$@"
fi

# Signs with a copy of the -f key whose stub has the user-presence flag
# cleared, so the YubiKey signs without a tap. The flag lives only in the
# private stub, never in the public key, so the signature still matches the
# key GitHub holds. ~/.ssh is never written. git passes `-f <path>` as two
# arguments; the joined `-f<path>` form is not handled.
sign_without_touch() {
  local args=() prev="" key=""
  # Global, not local: the EXIT trap reads it after this function returns.
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  for arg in "$@"; do
    if [ "$prev" = "-f" ]; then
      key=${arg%.pub}
      args+=("$tmp/k.pub")
    else
      args+=("$arg")
    fi
    prev="$arg"
  done
  install -m 600 "$key" "$tmp/k"
  install -m 644 "$key.pub" "$tmp/k.pub"
  # stdout carries the signature back to git: the -p step's chatter stays off it.
  if ! "$openssh_keygen" -p -O no-touch-required -P "" -N "" -f "$tmp/k" >/dev/null; then
    echo "yubikey-touch-ssh-keygen: could not clear the touch flag on a copy of $key" >&2
    echo "(ssh-keygen -p -O no-touch-required needs OpenSSH >= $min_openssh)" >&2
    exit 1
  fi
  "$openssh_keygen" "${args[@]}"
}

sign_with_touch_alert() {
  # stdout carries the signature back to git - keep the alert off it, and
  # off stdin too, which is the pipe git streams the payload down.
  "$beep" </dev/null >/dev/null 2>&1 &
  loop=$!
  # Best-effort: an untrapped signal skips this, so beep also stops itself.
  trap 'kill "$loop" 2>/dev/null || true' EXIT

  set +e
  "$openssh_keygen" "$@"
  rc=$?
  set -e
  exit "$rc"
}

case "$no_touch_signing" in
  1) sign_without_touch "$@" ;;
  0) sign_with_touch_alert "$@" ;;
  *)
    echo "yubikey-touch-ssh-keygen: no_touch_signing must be 0 or 1, got '$no_touch_signing'" >&2
    exit 1
    ;;
esac
