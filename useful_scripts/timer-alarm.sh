function parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --timer)
      MODE="timer"
      shift
      DUR=""
      # Collect all following non-flag tokens as part of the duration
      while [[ $# -gt 0 && "$1" != --* ]]; do
        DUR+="${DUR:+ }$1"
        shift
      done
      [[ -n "$DUR" ]] || {
        printf 'Error: --timer needs a duration\n' >&2
        exit 2
      }
      ;;
    --alarm)
      MODE="alarm"
      WHEN="$2"
      shift 2
      ;;
    --message)
      MSG="$2"
      shift 2
      ;;
    --title)
      TITLE="$2"
      shift 2
      ;;
    --detach)
      DETACH=1
      shift
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    --sudo-cache)
      SUDOCACHE=1
      shift
      ;;
    --dry-run)
      DRYRUN=1
      shift
      ;;
    --action)
      case "$2" in
      none | upgrade | reboot | shutdown | upgrade+reboot | upgrade+shutdown)
        ACTION="$2"
        shift 2
        ;;
      *)
        printf 'Error: invalid --action "%s"\n' "$2" >&2
        exit 2
        ;;
      esac
      ;;
    --logdir)
      LOGDIR_SET="$2"
      shift 2
      ;;
    --help | -h)
      show_help
      exit 0
      ;;
    --until)
      UNTIL_EPOCH="$2"
      shift 2
      ;; # internal
    --internal-detached)
      INTERNAL_DETACHED=1
      shift
      ;; # internal
    *)
      printf 'Error: unknown argument "%s"\n' "$1" >&2
      exit 2
      ;;
    esac
  done
}
