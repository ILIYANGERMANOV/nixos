# shellcheck shell=bash
main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    start) cmd_start "$@" ;;
    stop) cmd_stop "$@" ;;
    restart) cmd_restart "$@" ;;
    resolve) cmd_resolve "$@" ;;
    terminate) cmd_terminate "$@" ;;
    status) cmd_status ;;
    stats) cmd_stats ;;
    mem) cmd_mem ;;
    kill) cmd_kill "$@" ;;
    free-disk) cmd_free_disk "$@" ;;
    root-shells) cmd_root_shells ;;
    deploy) cmd_deploy ;;
    rollback | reboot | poweroff | gc) cmd_root_op "$cmd" ;;
    boot) cmd_boot "$@" ;;
    help | --help | -h) usage ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

usage() {
  cat <<'EOF'
factory-ctl - run the software factory

  start <name|git-url> [name]   clone if needed, start, and start at boot
  stop [--force] <name>         stop, and do not start at boot
  restart [--force] <name>      restart a running server
  resolve <name>                SSH URLs of the bot's repositories named <name>
  terminate [--force] [name]    end live sessions; servers keep running
  status                        servers, sessions, local work, last deploy
  stats                         RAM, disk, CPU, temps, fan, battery; health
  mem                           the biggest cgroups and processes by memory
  kill [--force] <pid>          end a process of this user, TERM then KILL
  kill ghcid <worktree>|--all   stop the GHCi daemons of a worktree, or all
  free-disk plan|apply          list or delete what can be reclaimed
  root-shells                   keep main's dev shells and flake inputs from GC
  deploy                        deploy main's tip once CI is green
  rollback | reboot | poweroff | gc
                                root operations, run by fixed units

Exit codes: 2 = refused, rerun with --force; 3 = not cloned, needs a URL.
EOF
}

main "$@"
