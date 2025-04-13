#!/bin/bash
###############################################################################
# countdown_timer.sh
#
# This script displays a live countdown timer in the format HH:MM:SS.
# While the seconds countdown every second, the hours and minutes only 
# update when they cross a full minute or hour boundary.
#
# Usage: ./countdown_timer.sh -H hours -M minutes -S seconds
#
# Options:
#   -H hours     Delay in hours (default: 0).
#   -M minutes   Delay in minutes (default: 0).
#   -S seconds   Delay in seconds (default: 0).
#
# Example:
#   ./countdown_timer.sh -H 0 -M 20 -S 0
#       Sets a countdown timer for 20 minutes.
#
# Author: [Your Name]
# Date: [Today's Date]
###############################################################################

# Function to display usage information.
usage() {
    cat <<EOF
Usage: $(basename "$0") -H hours -M minutes -S seconds
    -H hours     Delay in hours (default: 0)
    -M minutes   Delay in minutes (default: 0)
    -S seconds   Delay in seconds (default: 0)
Example:
    $(basename "$0") -H 0 -M 20 -S 0
    Sets a countdown timer for 20 minutes.
EOF
    exit 1
}

# Default values.
HOURS=0
MINUTES=0
SECONDS=0

# Parse command-line options.
while getopts "H:M:S:h" opt; do
    case "$opt" in
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

# Validate that the inputs are non-negative integers.
if ! [[ "$HOURS" =~ ^[0-9]+$ && "$MINUTES" =~ ^[0-9]+$ && "$SECONDS" =~ ^[0-9]+$ ]]; then
    echo "Error: Hours, minutes, and seconds must be non-negative integers." >&2
    usage
fi

# Compute the total delay in seconds.
TOTAL_DELAY=$(( HOURS * 3600 + MINUTES * 60 + SECONDS ))

# Ensure a positive delay.
if [ "$TOTAL_DELAY" -le 0 ]; then
    echo "Error: The total delay must be greater than 0 seconds." >&2
    usage
fi

# Countdown loop.
while [ $TOTAL_DELAY -ge 0 ]; do
    # Calculate remaining hours, minutes, seconds.
    cur_hours=$(( TOTAL_DELAY / 3600 ))
    cur_minutes=$(( (TOTAL_DELAY % 3600) / 60 ))
    cur_seconds=$(( TOTAL_DELAY % 60 ))

    # Print the countdown timer.
    # The "\r" returns the cursor to the beginning of the line to update in place.
    printf "\rTime left: %02d:%02d:%02d" "$cur_hours" "$cur_minutes" "$cur_seconds"

    # Sleep for one second before updating.
    sleep 1

    # Decrement the total seconds remaining.
    TOTAL_DELAY=$(( TOTAL_DELAY - 1 ))
done

# Print a newline once the countdown is complete.
echo -e "\nCountdown complete!"

