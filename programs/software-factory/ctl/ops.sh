# shellcheck shell=bash disable=SC2154 # set by another fragment: the assembled script is checked whole
# Root operations. This account has no sudo: each one starts a fixed root unit
# that polkit lets it start and nothing else (modules/nixos/server/ops.nix).
# Results land in $ops_state_dir/last.json, which `status` shows.

# deploy: ask GitHub for a deploy of main's tip and wait for that request. The
# workflow refuses unless CI passed on the commit; once it has created the
# deployment, the server picks it up within a minute.
cmd_deploy() {
  local before run
  before=$(latest_deploy_run)
  gh workflow run "$deploy_workflow" --repo "$deploy_repo" --ref main
  # The dispatch returns before the run exists.
  for _ in $(seq 30); do
    run=$(latest_deploy_run)
    [ "$run" = "$before" ] || break
    sleep 2
  done
  [ "$run" != "$before" ] || die "the deploy workflow did not start; see https://github.com/$deploy_repo/actions"
  if gh run watch "$run" --repo "$deploy_repo" --exit-status >/dev/null; then
    echo "Deploy of $deploy_repo@main requested. The server picks it up within a minute."
    echo "Follow it with: factory-ctl status"
  else
    gh run view "$run" --repo "$deploy_repo" --log-failed 2>/dev/null | tail -n 5 >&2 || true
    die "the deploy request failed: https://github.com/$deploy_repo/actions/runs/$run"
  fi
}

latest_deploy_run() {
  gh run list --repo "$deploy_repo" --workflow "$deploy_workflow" --limit 1 --json databaseId --jq '.[0].databaseId // ""'
}

# rollback | reboot | gc: start the matching root unit and return at once.
cmd_root_op() {
  systemctl start --no-block "factory-$1.service"
  echo "Started factory-$1. Check the result with: factory-ctl status"
}
