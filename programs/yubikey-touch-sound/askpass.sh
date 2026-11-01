# shellcheck shell=bash disable=SC2154 # set by another fragment: the assembled script is checked whole
case "${1-}" in
  "Confirm user presence"*) ;;
  *)
    echo "yubikey-touch-askpass: refusing unexpected prompt: ${1-<empty>}" >&2
    exit 1
    ;;
esac

# ssh took the askpass branch, so it did not print the notice itself.
echo "$1" >&2

exec "$beep"
