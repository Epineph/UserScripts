#!/usr/bin/env bash
# --- Run a foreground command on a spare VT without changing boot settings. ---
set -euo pipefail

function usage()
{
  cat <<'EOF'
Usage: tty-ionice.sh [--dry-run] -- COMMAND [ARG ...]
       tty-ionice.sh --help

Switch to a free Linux console, run COMMAND as your normal user with
ionice -c 2 -n 0, then return to the previous console. Keep Hyprland and
SDDM running; never change systemd targets or service enablement.

Options:
  --dry-run  Print the command without sudo, execution, or switching consoles.
  --help     Show this help.

Examples:
  ./tty-ionice.sh --dry-run -- ninja -C "$HOME/llvm-build" -j 4
  ./tty-ionice.sh -- ninja -C "$HOME/llvm-build" -j 4
  ./tty-ionice.sh -- bash -c 'printf "Console test\n"; sleep 5'

Run from a local desktop terminal as your normal user, not with sudo.
sudo is requested only to allocate the VT; the workload drops to your UID.
Working directory and PATH are preserved, but other custom environment
variables are not guaranteed. Use env NAME=value COMMAND when needed.
Commands must be executables (use bash -c or zsh -c for shell syntax).
The workload exit status is returned. Ctrl+C on the new VT interrupts it.
Output appears on the VT. Use your command's logging options to retain it.
Hyprland applications remain in memory and may still perform background work.
The console workload is accessible to anyone physically at the keyboard.
The usual desktop idle lock can still engage. Ctrl+Alt+F1 returns to this
host's desktop manually if automatic return is interrupted.
Requires Linux, sudo, openvt (kbd), and ionice/runuser (util-linux).
EOF
}

function die()
{
  printf 'tty-ionice: %s\n' "$*" >&2
  exit 1
}

preview=false
while (($#)); do
  case "$1" in
  --help | -h)
    usage
    exit 0
    ;;
  --dry-run)
    preview=true
    shift
    ;;
  --)
    shift
    break
    ;;
  *) die 'Expected -- before COMMAND; see --help.' ;;
  esac
done
(($#)) || die 'Missing command; see --help.'
((EUID != 0)) || die 'Run as your normal user, without sudo.'
[[ -z ${SSH_CONNECTION:-} ]] || die 'Run from a local terminal, not SSH.'
workdir=$PWD
workload=(/usr/bin/ionice -c 2 -n 0 -- "$@")
printf 'Working directory: %s\nCommand:' "$workdir"
printf ' %q' "${workload[@]}"
printf '\n'
if "$preview"; then
  exit 0
fi
for program in sudo openvt runuser ionice bash mktemp; do
  [[ -x /usr/bin/$program ]] || die "Missing /usr/bin/$program."
done
[[ -t 0 && -t 1 ]] || die 'An interactive local terminal is required.'
/usr/bin/sudo -v

# --- openvt's status is not the workload status: record it as the user. ---
result_dir=$(mktemp -d /tmp/tty-ionice.XXXXXXXX)
trap 'rm -f -- "$result_dir/status"; rmdir -- "$result_dir"' EXIT
launch_status=0
/usr/bin/sudo /usr/bin/openvt -s -w -- \
  /usr/bin/runuser -u "$(id -un)" -- \
  /usr/bin/env "PATH=$PATH" TERM=linux /usr/bin/bash -c '
    result=$1
    directory=$2
    shift 2
    function finish() {
      printf "%s\n" "$?" > "$result/status"
    }
    trap finish EXIT
    trap "exit 130" INT
    trap "exit 143" TERM
    trap "exit 129" HUP
    cd -- "$directory" || exit 1
    "$@"
    exit "$?"
  ' tty-ionice "$result_dir" "$workdir" "${workload[@]}" || launch_status=$?
if ((launch_status != 0)); then
  die "Console launcher failed (status $launch_status)."
fi
[[ -s $result_dir/status ]] || die 'Workload status missing; check the console.'
read -r status <"$result_dir/status"
if [[ ! $status =~ ^[0-9]+$ ]] || ((status > 255)); then
  die 'Invalid workload status.'
fi
printf 'Workload exited with status %s.\n' "$status"
exit "$status"
