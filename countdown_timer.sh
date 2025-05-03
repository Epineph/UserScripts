#!/usr/bin/env bash
###############################################################################
# countdown_power.sh
#
# This script displays a live countdown timer in the format HH:MM:SS for a
# specified time delay and then performs a power operation:
# either reboot (-r) or shutdown (-s).
#
# Usage: ./countdown_power.sh -r|-s [-H hours] [-M minutes] [-S seconds]
#
# Options:
#   -r           Reboot the system after the countdown.
#   -s           Shutdown the system after the countdown.
#   -H hours     Delay in hours (default: 0).
#   -M minutes   Delay in minutes (default: 0).
#   -S seconds   Delay in seconds (default: 0).
#   -h           Display this help message.
#
# Examples:
#   ./countdown_power.sh -r -H 0 -M 20 -S 0
#       Reboots the system after a 20-minute countdown.
#
#   ./countdown_power.sh -s -M 5
#       Shuts down the system after a 5-minute countdown.
#
# Author: [Your Name]
# Date: [Today's Date]
###############################################################################

# Function to display the usage/help message.
usage() {
    cat <<EOF
Usage: $(basename "$0") -r|-s [-H hours] [-M minutes] [-S seconds]
  -r           Reboot the system after the countdown.
  -s           Shutdown the system after the countdown.
  -H hours     Delay in hours (default: 0).
  -M minutes   Delay in minutes (default: 0).
  -S seconds   Delay in seconds (default: 0).
  -h           Show this help message.
Example:
  $(basename "$0") -r -H 0 -M 20 -S 0
  This schedules a reboot after a countdown of 20 minutes.
EOF
    exit 1
}

# Initialize default time values.
HOURS=0
MINUTES=0
SECONDS=0
MODE=""

# Parse command-line options.
while getopts "rsH:M:S:h" opt; do
    case "$opt" in
        r)
            if [[ -n "$MODE" ]]; then
                echo "Error: Specify only one mode: -r for reboot or -s for shutdown." >&2
                usage
            fi
            MODE="reboot"
            ;;
        s)
            if [[ -n "$MODE" ]]; then
                echo "Error: Specify only one mode: -r for reboot or -s for shutdown." >&2
                usage
            fi
            MODE="shutdown"
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
        h)
            usage
            ;;
        *)
            usage
            ;;
    esac
done

# Ensure that a mode was provided.
if [ -z "$MODE" ]; then
    echo "Error: You must specify either -r (reboot) or -s (shutdown)." >&2
    usage
fi

# Validate that the provided time values are non-negative integers.
if ! [[ "$HOURS" =~ ^[0-9]+$ && "$MINUTES" =~ ^[0-9]+$ && "$SECONDS" =~ ^[0-9]+$ ]]; then
    echo "Error: Hours, minutes, and seconds must be non-negative integers." >&2
    usage
fi

# Calculate the total delay in seconds.
TOTAL_DELAY=$(( HOURS * 3600 + MINUTES * 60 + SECONDS ))
if [ "$TOTAL_DELAY" -le 0 ]; then
    echo "Error: The total delay must be greater than 0 seconds." >&2
    usage
fi

# Provide feedback about the scheduled action.
echo "Scheduled $MODE in ${HOURS} hour(s), ${MINUTES} minute(s), and ${SECONDS} second(s) (Total: ${TOTAL_DELAY} second(s))."

# Countdown timer loop.
while [ $TOTAL_DELAY -gt 0 ]; do
    # Calculate remaining hours, minutes, and seconds.
    cur_hours=$(( TOTAL_DELAY / 3600 ))
    cur_minutes=$(( (TOTAL_DELAY % 3600) / 60 ))
    cur_seconds=$(( TOTAL_DELAY % 60 ))
    
    # Print the countdown timer; \r returns the cursor to the start of the line.
    printf "\rTime left: %02d:%02d:%02d" "$cur_hours" "$cur_minutes" "$cur_seconds"
    
    # Wait for one second.
    sleep 1
    
    # Decrement the total delay.
    TOTAL_DELAY=$(( TOTAL_DELAY - 1 ))
done

# Add a newline after the countdown is complete.
echo -e "\nTime is up! Executing $MODE now..."

# Execute the corresponding command using sudo.
if [ "$MODE" = "reboot" ]; then
    sudo systemctl reboot
elif [ "$MODE" = "shutdown" ]; then
    sudo systemctl poweroff
fi
