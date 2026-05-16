#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# pacman-events
#
# Show recent pacman package events as a sortable table.
# Useful for diagnosing breakage after package installation or upgrades.
# -----------------------------------------------------------------------------

set -euo pipefail

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------

mode="all"
order="desc"
limit="80"
all_logs="false"
format="table"
declare -a logs=("/var/log/pacman.log")

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------

function show_help() {
  cat <<'EOF'
pacman-events

Show pacman package events sorted by time.

USAGE
  pacman-events [OPTIONS]

OPTIONS
  -h, --help
      Show this help text.

  -m, --mode MODE
      Event type to show.

      Values:
        all
        installed
        upgraded
        reinstalled
        removed

      Default:
        all

  -o, --order ORDER
      Sort order.

      Values:
        asc
        desc

      Default:
        desc

  -n, --limit N
      Maximum number of rows to show.

      Default:
        80

      Use 0 for no limit.

  --all-logs
      Include rotated pacman logs, e.g. pacman.log.1, pacman.log.2.gz,
      pacman.log.3.zst, if present.

  --log PATH
      Read a specific pacman log file. Can be given multiple times.

  --format FORMAT
      Output format.

      Values:
        table
        tsv

      Default:
        table

EXAMPLES
  pacman-events

  pacman-events --mode installed --order desc --limit 50

  pacman-events --mode upgraded --order desc --limit 100

  pacman-events --mode all --order desc --limit 150

  pacman-events --all-logs --mode all --order desc --limit 200

  pacman-events --format tsv --mode upgraded --limit 0

NOTES
  For diagnosing kernel/initramfs breakage, this is usually best:

    pacman-events --mode all --order desc --limit 150

  Kernel/initramfs issues are commonly caused by upgrades, not only newly
  installed packages.
EOF
}

# -----------------------------------------------------------------------------
# Utilities
# -----------------------------------------------------------------------------

function die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

function lower() {
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'
}

function read_log() {
  local file="$1"

  [[ -r "$file" ]] || return 0

  case "$file" in
    *.zst)
      command -v zstdcat >/dev/null 2>&1 ||
        die "zstdcat is required to read: $file"
      zstdcat -- "$file"
      ;;
    *.gz)
      gzip -cd -- "$file"
      ;;
    *.xz)
      xzcat -- "$file"
      ;;
    *.bz2)
      bzcat -- "$file"
      ;;
    *)
      cat -- "$file"
      ;;
  esac
}

function collect_all_logs() {
  local file

  logs=()

  shopt -s nullglob
  for file in /var/log/pacman.log*; do
    logs+=("$file")
  done
  shopt -u nullglob

  ((${#logs[@]} > 0)) || die "no pacman logs found under /var/log"
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

while (($# > 0)); do
  case "$1" in
    -h|--help)
      show_help
      exit 0
      ;;

    -m|--mode)
      (($# >= 2)) || die "--mode requires a value"
      mode="$(lower "$2")"
      shift 2
      ;;

    -o|--order)
      (($# >= 2)) || die "--order requires a value"
      order="$(lower "$2")"
      shift 2
      ;;

    -n|--limit)
      (($# >= 2)) || die "--limit requires a value"
      limit="$2"
      shift 2
      ;;

    --all-logs)
      all_logs="true"
      shift
      ;;

    --log)
      (($# >= 2)) || die "--log requires a path"

      if ((${#logs[@]} == 1)) &&
        [[ "${logs[0]}" == "/var/log/pacman.log" ]]; then
        logs=()
      fi

      logs+=("$2")
      shift 2
      ;;

    --format)
      (($# >= 2)) || die "--format requires a value"
      format="$(lower "$2")"
      shift 2
      ;;

    *)
      die "unknown option: $1"
      ;;
  esac
done

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------

case "$mode" in
  all|installed|upgraded|reinstalled|removed) ;;
  *) die "invalid mode: $mode" ;;
esac

case "$order" in
  asc|desc) ;;
  *) die "invalid order: $order" ;;
esac

case "$format" in
  table|tsv) ;;
  *) die "invalid format: $format" ;;
esac

[[ "$limit" =~ ^[0-9]+$ ]] || die "--limit must be a non-negative integer"

if [[ "$all_logs" == "true" ]]; then
  collect_all_logs
fi

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

for log in "${logs[@]}"; do
  read_log "$log"
done |
  awk -v mode="$mode" '
    function wanted(action) {
      if (mode == "all") {
        return action ~ /^(installed|upgraded|reinstalled|removed)$/
      }

      return action == mode
    }

    /^\[[^]]+\] \[ALPM\] (installed|upgraded|reinstalled|removed) / {
      timestamp = $0
      sub(/^\[/, "", timestamp)
      sub(/\].*$/, "", timestamp)

      line = $0
      sub(/^\[[^]]+\] \[ALPM\] /, "", line)

      action = line
      sub(/ .*/, "", action)

      if (!wanted(action)) {
        next
      }

      rest = line
      sub(/^[^ ]+ /, "", rest)

      package = rest
      sub(/ .*/, "", package)

      version = rest
      sub(/^[^ ]+ \(/, "", version)
      sub(/\)$/, "", version)

      oldver = "-"
      newver = version

      if (action == "upgraded") {
        split(version, parts, " -> ")
        oldver = parts[1]
        newver = parts[2]
      }

      printf "%s\t%s\t%s\t%s\t%s\n",
        timestamp, action, package, oldver, newver
    }
  ' > "$tmp"

if [[ "$order" == "desc" ]]; then
  sort_args=(-t $'\t' -k1,1r)
else
  sort_args=(-t $'\t' -k1,1)
fi

if [[ "$format" == "tsv" ]]; then
  printf 'timestamp\taction\tpackage\told_version\tnew_version\n'
  sort "${sort_args[@]}" "$tmp" |
    awk -v limit="$limit" 'limit == 0 || NR <= limit'
else
  {
    printf 'timestamp\taction\tpackage\told_version\tnew_version\n'
    sort "${sort_args[@]}" "$tmp" |
      awk -v limit="$limit" 'limit == 0 || NR <= limit'
  } | column -t -s $'\t'
fi
