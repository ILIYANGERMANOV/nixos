# shellcheck shell=bash disable=SC2154 # set by another fragment: the assembled script is checked whole
# Deploys the newest pending GitHub Deployment of this host, as root.
#
# Run every minute by a timer. The workflow that creates deployments
# (.github/workflows/deploy-factory.yml) is a convenience, not the boundary:
# anyone with write access can create a deployment through the API, so the
# commit is checked here to be main's tip before anything is built. An older
# commit of main is refused too, or a deployment could roll the server back to
# a configuration that predates a fix.
#
# The new system is activated with `test` first, so a reboot still boots the
# old one. Only once the health gate passes does it become the boot default.
main() {
  mkdir -p "$state_dir"
  exec 9>"$state_dir/deploy.lock"
  flock -n 9 || exit 0

  local deployment statuses
  deployment=$(api GET "/repos/$repo/deployments?environment=$environment&per_page=1" | jq -c '.[0] // empty')
  [ -n "$deployment" ] || exit 0
  id=$(jq -r .id <<<"$deployment")
  sha=$(jq -r .sha <<<"$deployment")
  # A deployment with any status was handled already, or is being handled.
  # shellcheck disable=SC2310 # no answer from GitHub: the next tick retries
  statuses=$(api GET "/repos/$repo/deployments/$id/statuses?per_page=1" | jq length) || exit 0
  [ "$statuses" -eq 0 ] || exit 0

  # Anything unexpected from here on still reaches GitHub as a failure.
  set -o errtrace
  trap 'report failure "Deploy failed; see journalctl -u factory-deploy"' ERR
  report in_progress "Building $sha"
  deploy
}

deploy() {
  local new old
  # shellcheck disable=SC2310 # a predicate: refusing is the failure path
  is_main_tip "$sha" || fail "$sha is not the tip of main"
  new=$(nix build --no-link --print-out-paths \
    "github:$repo/$sha#nixosConfigurations.$host.config.system.build.toplevel") ||
    fail "Build failed, nothing changed"
  old=$(readlink -f "$current_system")
  [ "$new" != "$old" ] || {
    report success "Already running $sha"
    return 0
  }

  # A failed activation can still leave the box reachable; the gate decides.
  "$new/bin/switch-to-configuration" test || true
  # shellcheck disable=SC2310 # the gate: a failure here rolls back
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
is_main_tip() {
  local tip
  tip=$(api GET "/repos/$repo/commits/main" | jq -r .sha)
  [ "$tip" = "$1" ]
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
# response; it is kept for `factory-ctl status`. A subshell, for its EXIT trap:
# `set -e` leaves on a failed curl, and a RETURN trap does not fire on exit.
# ERR stays with the caller: run in here too, each failed report would report
# again, without end while GitHub is down.
api() (
  trap - ERR
  local method="$1" path="$2" tmp body=()
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  if [ "$method" != GET ]; then
    cat >"$tmp/body"
    body=(--data-binary "@$tmp/body")
  fi
  printf 'header = "Authorization: Bearer %s"\n' "$(<"$token_file")" |
    curl -fsS -K - -X "$method" -D "$tmp/headers" "${body[@]}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com$path"
  sed -n 's/^github-authentication-token-expiration: *//Ip' "$tmp/headers" | tr -d '\r' >"$tmp/expires"
  [ ! -s "$tmp/expires" ] || mv "$tmp/expires" "$state_dir/token-expires"
  # A caller reading the body in `$(...)` runs with -e off: a lost expiry note
  # must not read as a failed request there.
  true
)

main "$@"
