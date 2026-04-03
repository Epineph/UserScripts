#!/bin/bash
############################################################################
###
# schedule_power.sh
#
# Displays a live countdown and then either reboots or shuts down the system.
# Optionally, before rebooting, it can perform a full system update
# (Arch-based: yay + mkinitcpio + grub-mkconfig).
#
# Usage: schedule_power.sh -r|-s [-u] [-H hours] [-M minutes] [-S seconds]
#
#   -r           Reboot the system after the countdown.
#   -s           Shutdown the system after the countdown.
#   -u           When rebooting (-r), run system update commands first.
#   -H hours     Delay in hours (default: 0).
#   -M minutes   Delay in minutes (default: 0).
#   -S seconds   Delay in seconds (default: 0).
#   -h           Show this help message.
#
# Examples:
#   # Simple reboot in 20 minutes
#   schedule_power.sh -r -M 20
#
#   # Reboot in 5 minutes, performing an update first
#   schedule_power.sh -r -u -M 5
#
#   # Shutdown in 1 hour and 30 seconds
#   schedule_power.sh -s -H 1 -S 30
#
# Author: Your Name
# Date:   2025-05-14
############################################################################

# Print usage/help message
usage() {
    cat <<EOF
Usage: $(basename "$0") -r|-s [-u] [-H hours] [-M minutes] [-S seconds]
  -r           Reboot the system after the countdown.
  -s           Shutdown the system after the countdown.
  -u           (Only with -r) Perform system update before reboot.
  -H hours     Delay in hours (default: 0).
  -M minutes   Delay in minutes (default: 0).
  -S seconds   Delay in seconds (default: 0).
  -h           Show this help message.
Example:
  $(basename "$0") -r -u -M 5
    # Performs a full update, then reboots after 5 minutes.
EOF
    exit 1
}

# Default values
HOURS=0
MINUTES=0
SECONDS=0
MODE=""
DO_UPDATE=false

# Parse options
while getopts "rsuH:M:S:h" opt; do
    case "$opt" in
        r)
            # Reboot mode
            if [[ -n "$MODE" ]]; then
                echo "Error: Choose only one of -r (reboot) or -s (shutdown)." >&2
                usage
            fi
            MODE="reboot"
            ;;
        s)
            # Shutdown mode
            if [[ -n "$MODE" ]]; then
                echo "Error: Choose only one of -r (reboot) or -s (shutdown)." >&2
                usage
            fi
            MODE="shutdown"
            ;;
        u)
            # Update flag (only valid with reboot)
            DO_UPDATE=true
            ;;
        H)
            HOURS="$OPTARG"
            ;;
        M)
            MINUTES="$OPTARG"
            ;;
        S)
            SECONDS="$OPTARG"
            ;;
        h|*)
            usage
            ;;
    esac
done

# Must choose reboot or shutdown
if [[ -z "$MODE" ]]; then
    echo "Error: You must specify either -r (reboot) or -s (shutdown)." >&2
    usage
fi

# Update only makes sense when rebooting
if $DO_UPDATE && [[ "$MODE" != "reboot" ]]; then
    echo "Error: -u (update) is only valid with -r (reboot)." >&2
    usage
fi

# Validate time inputs are non-negative integers
for var in HOURS MINUTES SECONDS; do
    val="${!var}"
    if ! [[ "$val" =~ ^[0-9]+$ ]]; then
        echo "Error: $var must be a non-negative integer." >&2
        usage
    fi
done

# Compute total delay in seconds
TOTAL_DELAY=$(( HOURS * 3600 + MINUTES * 60 + SECONDS ))
if (( TOTAL_DELAY <= 0 )); then
    echo "Error: Total delay must be greater than zero." >&2
    usage
fi

# Inform the user
echo "Scheduled $MODE in ${HOURS}h ${MINUTES}m ${SECONDS}s (total ${TOTAL_DELAY}s)."
if $DO_UPDATE; then
    echo "Will perform system update before reboot."
fi

# Countdown loop
while (( TOTAL_DELAY > 0 )); do
    h=$(( TOTAL_DELAY / 3600 ))
    m=$(( (TOTAL_DELAY % 3600) / 60 ))
    s=$(( TOTAL_DELAY % 60 ))
    printf "\rTime left: %02d:%02d:%02d" "$h" "$m" "$s"
    sleep 1
    (( TOTAL_DELAY-- ))
done
echo -e "\nTime is up! Executing $MODE now..."

# If requested, perform update steps before reboot
if $DO_UPDATE; then
    echo "Starting system update..."
    # Synchronize and update all packages without confirmation
    yay -Syyu --noconfirm
    # Regenerate initramfs for all installed kernels
    sudo mkinitcpio -P
    # Rebuild GRUB configuration
    sudo grub-mkconfig -o /boot/grub/grub.cfg
    echo "Update complete."
fi

# Final power action
if [[ "$MODE" == "reboot" ]]; then
    sudo systemctl reboot
else
    sudo systemctl poweroff
fi

