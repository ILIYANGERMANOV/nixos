# Deploys the newest pending GitHub Deployment of this host, as root.
#
# Run every minute by a timer. The workflow that creates deployments
# (.github/workflows/deploy-factory.yml) is a convenience, not the boundary:
# anyone with write access can create a deployment through the API, so the
# commit is checked here to be on main before anything is built.
#
# The new system is activated with `test` first, so a reboot still boots the
# old one. Only once the health gate passes does it become the boot default.
main() {
  mkdir -p "$state_dir"
  exec 9>"$state_dir/deploy.lock"
  flock -n 9 || exit 0

  local deployment
  deployment=$(api GET "/repos/$repo/deployments?environment=$environment&per_page=1" | jq -c '.[0] // empty')
  [ -n "$deployment" ] || exit 0
  id=$(jq -r .id <<<"$deployment")
  sha=$(jq -r .sha <<<"$deployment")
  # A deployment with any status was handled already, or is being handled.
  [ "$(api GET "/repos/$repo/deployments/$id/statuses?per_page=1" | jq length)" -eq 0 ] || exit 0

  # Anything unexpected from here on still reaches GitHub as a failure.
  set -o errtrace
  trap 'report failure "Deploy failed; see journalctl -u factory-deploy"' ERR
  report in_progress "Building $sha"
  deploy
}

deploy() {
  local new old
  on_main "$sha" || fail "$sha is not on main"
  new=$(nix build --no-link --print-out-paths \
    "github:$repo/$sha#nixosConfigurations.$host.config.system.build.toplevel") ||
    fail "Build failed, nothing changed"
  old=$(readlink -f "$current_system")
  [ "$new" != "$old" ] || { report success "Already running $sha"; return 0; }

  # A failed activation can still leave the box reachable; the gate decides.
  "$new/bin/switch-to-configuration" test || true
  if healthy; then
    nix-env -p "$profile" --set "$new"
    "$new/bin/switch-to-configuration" boot
    report success "Deployed $sha"
  else
    "$old/bin/switch-to-configuration" test
    fail "Health check failed after switching; rolled back"
  fi
}

fail() {
  report failure "$1"
  exit 1
}
# The compare API answers "identical" or "behind" when main contains the commit.
on_main() {
  local status
  status=$(api GET "/repos/$repo/compare/main...$1" | jq -r .status)
  case "$status" in
    identical | behind) return 0 ;;
    *) return 1 ;;
  esac
}

# Reachable again the way it was reached before: tailscale up, sshd running,
# GitHub answering. Retries for a while, because services restart on switch.
healthy() {
  local attempt
  for attempt in $(seq "$health_attempts"); do
    if tailscale status --json | jq -e '.BackendState == "Running"' >/dev/null &&
      systemctl is-active --quiet sshd.service &&
      curl -fsS -m 10 -o /dev/null https://api.github.com/zen; then
      return 0
    fi
    [ "$attempt" -eq "$health_attempts" ] || sleep 5
  done
  return 1
}

# Records the outcome for `factory-ctl status` and posts it to GitHub.
report() {
  local state="$1" message="$2"
  record deploy "$state" "$sha" "$message"
  jq -n --arg state "$state" --arg description "$message" '{$state, $description}' |
    api POST "/repos/$repo/deployments/$id/statuses" >/dev/null
}

# GitHub's REST API with the deploy token. The token reaches curl in a config
# on stdin, never in argv, so a POST body arrives on this function's stdin and
# is staged in a file first. GitHub sends the token's expiry with every
# response; it is kept for `factory-ctl status`.
api() {
  local method="$1" path="$2" tmp body=()
  tmp=$(mktemp -d)
  if [ "$method" != GET ]; then
    cat >"$tmp/body"
    body=(--data-binary "@$tmp/body")
  fi
  printf 'header = "Authorization: Bearer %s"\n' "$(cat "$token_file")" |
    curl -fsS -K - -X "$method" -D "$tmp/headers" "${body[@]}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com$path"
  sed -n 's/^github-authentication-token-expiration: *//Ip' "$tmp/headers" | tr -d '\r' >"$tmp/expires"
  [ ! -s "$tmp/expires" ] || mv "$tmp/expires" "$state_dir/token-expires"
  rm -rf "$tmp"
}

main "$@"
