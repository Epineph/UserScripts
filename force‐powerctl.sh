#!/usr/bin/env bash
#
# force‐powerctl.sh
#
# DESCRIPTION:
#   Attempts to shut down or reboot the machine. First performs a graceful
#   request; if the machine does not actually power off or reboot within a
#   specified timeout, it will escalate to forced methods:
#     1. systemctl --force --force <action>
#     2. Direct SysRq magic (“echo o” for poweroff, “echo b” for reboot)
#
#   This is useful if, for example, some service hangs during shutdown and
#   prevents the normal sequence from completing.
#
# USAGE:
#   sudo ./force‐powerctl.sh [shutdown|reboot]
#
#   OPTIONS:
#     -h, --help    Show this help message and exit.
#
# EXAMPLES:
#   sudo ./force‐powerctl.sh reboot
#   sudo ./force‐powerctl.sh shutdown
#
# NOTE:
#   1. Must be run as root (or via sudo) because:
#      • systemctl commands for power management require elevated privileges.
#      • Writing to /proc/sysrq-trigger requires both sysrq be enabled
#        and root access.
#   2. This script relies on “kernel.sysrq=1” (or a nonzero value) in sysctl
#      so that writing to /proc/sysrq-trigger actually works. If SysRq is
#      disabled, the final‐fallback step may not succeed.
#   3. The “graceful” step uses a timeout of 10 seconds. You may adjust
#      SHUTDOWN_TIMEOUT below if you want a shorter or longer grace period.
#
################################################################################

set -euo pipefail

#——————————————————————————————————————————————————————————————————————
# CONFIGURATION
#——————————————————————————————————————————————————————————————————————

# Time (in seconds) to wait after the initial graceful request
# before escalating to a forced systemctl call.
SHUTDOWN_TIMEOUT=10

# Path to the SysRq trigger
SYSRQ_TRIGGER="/proc/sysrq-trigger"

#——————————————————————————————————————————————————————————————————————
# HELP & USAGE FUNCTION
#——————————————————————————————————————————————————————————————————————

show_help() {
    cat << EOF
force‐powerctl.sh: Forceful shutdown or reboot

Usage:
  sudo $0 [shutdown|reboot]

Options:
  -h, --help    Display this help message and exit

Description:
  1. Attempts a graceful \$action (“shutdown” or “reboot”) via \`systemctl \$action\`.
  2. Waits \${SHUTDOWN_TIMEOUT} seconds. If the system still appears to be "running",
     escalates to \`systemctl --force --force \$action\`.
  3. If that still does not power off/reboot within another \${SHUTDOWN_TIMEOUT} seconds,
     writes directly to \$SYSRQ_TRIGGER (“o” for shutdown, “b” for reboot).

  *** Requirements ***
    • Must run as root (or via sudo).
    • SysRq must be enabled (`kernel.sysrq` sysctl ≥ 1) for the final fallback to work.

Examples:
  sudo $0 reboot
  sudo $0 shutdown

EOF
}

#——————————————————————————————————————————————————————————————————————
# FUNCTION: check_root
#   Ensure the script is run as root. Exit if not.
#——————————————————————————————————————————————————————————————————————

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Error: This script must be run as root or via sudo." >&2
        exit 1
    fi
}

#——————————————————————————————————————————————————————————————————————
# FUNCTION: is_system_running
#   Uses `systemctl is-system-running` to gauge whether the system is still up.
#   Returns 0 if status is anything other than "offline" or "stopping".
#   Returns 1 if status is "offline" (i.e., already shut down).
#——————————————————————————————————————————————————————————————————————

is_system_running() {
    # “is-system-running” can return many states: starting, running, degraded,
    # maintenance, stopping, offline, etc. We consider "offline" as “powered off,”
    # otherwise “still running.”
    local state
    if ! state=$(systemctl is-system-running 2>/dev/null); then
        # If systemctl fails, we assume still running (e.g., D-Bus timeout).
        return 0
    fi

    case "$state" in
        offline)    return 1 ;;  # The system is effectively off
        *)          return 0 ;;  # Anything else → still up or in transition
    esac
}

#——————————————————————————————————————————————————————————————————————
# FUNCTION: try_graceful
#   Issues the normal graceful shutdown/reboot via systemctl.
#   Does not wait for completion here, just sends the request.
#   \$1 = action (“shutdown” or “reboot”).
#——————————————————————————————————————————————————————————————————————

try_graceful() {
    local action=$1

    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] Attempting graceful \${action} via systemctl..."
    # If action is “shutdown,” we map to “poweroff” target. For “reboot,” use “reboot”:
    if [[ "$action" == "shutdown" ]]; then
        systemctl poweroff || true
    else
        systemctl reboot   || true
    fi
}

#——————————————————————————————————————————————————————————————————————
# FUNCTION: try_force
#   Issues the forced shutdown/reboot via systemctl’s double-force flags.
#   \$1 = action (“shutdown” or “reboot”).
#   The first --force attempts immediate shutdown; the second bypasses service
#   stopping altogether.
#——————————————————————————————————————————————————————————————————————

try_force() {
    local action=$1

    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] Escalating to forced systemctl \${action} (double --force)…"
    if [[ "$action" == "shutdown" ]]; then
        systemctl --force --force poweroff || true
    else
        systemctl --force --force reboot   || true
    fi
}

#——————————————————————————————————————————————————————————————————————
# FUNCTION: sysrq_fallback
#   Direct SysRq fallback to immediately power off (“o”) or reboot (“b”).
#   \$1 = action (“shutdown” or “reboot”).
#   Precondition: /proc/sys/kernel/sysrq must be enabled (nonzero).
#——————————————————————————————————————————————————————————————————————

sysrq_fallback() {
    local action=$1

    # Check if /proc/cmdline or sysctl indicates SysRq is enabled.
    local sysrq_value
    if [[ -r /proc/sys/kernel/sysrq ]]; then
        sysrq_value=$(< /proc/sys/kernel/sysrq)
    else
        sysrq_value=0
    fi

    if [[ "$sysrq_value" -eq 0 ]]; then
        echo "Warning: SysRq is disabled (kernel.sysrq=0)."
        echo "         The final fallback may fail. To enable: ‘echo 1 > /proc/sys/kernel/sysrq’."
    else
        echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] Performing SysRq fallback for \${action}..."
        if [[ "$action" == "shutdown" ]]; then
            # “o” = poweroff (will cut power after sync/umount)
            echo "o" > "$SYSRQ_TRIGGER" 2>/dev/null || \
                echo "Error: Cannot write to \$SYSRQ_TRIGGER." >&2
        else
            # “b” = immediate reboot (no sync; may risk file system corruption)
            echo "b" > "$SYSRQ_TRIGGER" 2>/dev/null || \
                echo "Error: Cannot write to \$SYSRQ_TRIGGER." >&2
        fi
    fi
}

#——————————————————————————————————————————————————————————————————————
# MAIN SCRIPT LOGIC
#——————————————————————————————————————————————————————————————————————

main() {
    check_root

    # Parse arguments
    if [[ $# -eq 0 ]]; then
        echo "Error: Missing argument. Must specify 'shutdown' or 'reboot'." >&2
        show_help
        exit 1
    fi

    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        shutdown|reboot)
            ACTION=$1
            ;;
        *)
            echo "Error: Invalid argument '$1'. Use 'shutdown' or 'reboot'." >&2
            show_help
            exit 1
            ;;
    esac

    # STEP 1: Attempt graceful action
    try_graceful "$ACTION"

    # STEP 2: Wait a short time (grace period)
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] Waiting \$SHUTDOWN_TIMEOUT seconds to see if system powers off..."
    sleep "$SHUTDOWN_TIMEOUT"

    # STEP 3: Check if the system is still running
    if is_system_running; then
        echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] System still appears to be running; escalating..."
        try_force "$ACTION"

        # STEP 4: Wait again to see if forced systemctl worked
        echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] Waiting another \$SHUTDOWN_TIMEOUT seconds after forced systemctl..."
        sleep "$SHUTDOWN_TIMEOUT"

        # STEP 5: Final SysRq fallback if necessary
        if is_system_running; then
            echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] Forced systemctl did not succeed; attempting SysRq fallback..."
            sysrq_fallback "$ACTION"
        else
            # If system is now offline, exit successfully
            exit 0
        fi
    else
        # If graceful succeeded, exit
        exit 0
    fi

    # If everything fails, we can either loop or just exit. Here, we exit.
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] All attempts made. If the machine is still running, manual intervention is needed."
    exit 1
}

# Invoke main with all parameters
main "$@"

