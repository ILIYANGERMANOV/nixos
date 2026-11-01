# shellcheck shell=bash
echo "curl $*" >>"$CALLS"
method=GET headers=/dev/null body="" url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X)
      method="$2"
      shift
      ;;
    -D)
      headers="$2"
      shift
      ;;
    --data-binary)
      body="${2#@}"
      shift
      ;;
    -K)
      cat >"$GH/config"
      shift
      ;;
    -H | -m | -o) shift ;;
    https://*) url="$1" ;;
    *) ;;
  esac
  shift
done
printf 'HTTP/2 200\r\ngithub-authentication-token-expiration: 2027-01-01 00:00:00 UTC\r\n\r\n' >"$headers"
case "$method $url" in
  "GET https://api.github.com/zen") [ ! -e "$GH/github-down" ] ;;
  "GET "*/deployments\?*) cat "$GH/deployments.json" ;;
  "GET "*/statuses\?*) cat "$GH/statuses.json" ;;
  "GET "*/commits/main) cat "$GH/main.json" ;;
  "POST "*/statuses)
    [ ! -e "$GH/post-fails" ] || exit 22
    {
      cat "$body"
      echo
    } >>"$GH/posted"
    echo '{}'
    ;;
  *)
    echo "fake curl: unexpected $method $url" >&2
    exit 22
    ;;
esac
