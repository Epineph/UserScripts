#!/bin/bash
###############################################################################
# schedule_power.sh
#
# This script schedules either a system reboot or a shutdown after a
# specified delay. The delay can be provided in hours, minutes, and seconds.
#
# Usage: ./schedule_power.sh [-r|-s] [-H hours] [-M minutes] [-S seconds]
#
# Options:
#   -r           Schedule a reboot.
#   -s           Schedule a shutdown.
#   -H hours     Set the delay in hours (default: 0).
#   -M minutes   Set the delay in minutes (default: 0).
#   -S seconds   Set the delay in seconds (default: 0).
#   -h           Display this help message and exit.
#
# Examples:
#   ./schedule_power.sh -r -H 0 -M 20 -S 0
#       Schedules a reboot in 20 minutes.
#
# Author: [Your Name]
# Date: [Today's Date]
###############################################################################

# Function to display the usage/help message.
usage() {
  cat <<EOF
Usage: $(basename "$0") [-r|-s] [-H hours] [-M minutes] [-S seconds]
       -r           Schedule a reboot.
       -s           Schedule a shutdown.
       -H hours     Delay in hours (default 0).
       -M minutes   Delay in minutes (default 0).
       -S seconds   Delay in seconds (default 0).
       -h           Show this help message.
Example:
       $(basename "$0") -r -H 0 -M 20 -S 0
       This schedules a reboot in 20 minutes.
EOF
}

# Initialize default values for the time parameters.
MODE=""
HOURS=0
MINUTES=0
SECONDS=0

# Parse command-line options using getopts.
while getopts "rsH:M:S:h" opt; do
  case "$opt" in
    r)
      if [ -n "$MODE" ]; then
        echo "Error: Only one mode (-r or -s) may be specified." >&2
        usage
        exit 1
      fi
      MODE="reboot"
      ;;
    s)
      if [ -n "$MODE" ]; then
        echo "Error: Only one mode (-r or -s) may be specified." >&2
        usage
        exit 1
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
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

# Ensure that a mode was specified.
if [ -z "$MODE" ]; then
  echo "Error: You must specify either -r for reboot or -s for shutdown." >&2
  usage
  exit 1
fi

# Validate that the time inputs are non-negative integers.
if ! [[ "$HOURS" =~ ^[0-9]+$ ]] || ! [[ "$MINUTES" =~ ^[0-9]+$ ]] || ! [[ "$SECONDS" =~ ^[0-9]+$ ]]; then
  echo "Error: Hours, minutes, and seconds must be non-negative integers." >&2
  usage
  exit 1
fi

# Calculate the total delay in seconds.
TOTAL_DELAY=$(( HOURS * 3600 + MINUTES * 60 + SECONDS ))
if [ "$TOTAL_DELAY" -le 0 ]; then
  echo "Error: Total delay must be greater than 0 seconds." >&2
  usage
  exit 1
fi

# Provide feedback about the scheduled action.
echo "Scheduling ${MODE} in ${HOURS} hour(s), ${MINUTES} minute(s), and ${SECONDS} second(s)..."
echo "Total delay: ${TOTAL_DELAY} second(s)."

# Sleep for the total computed delay before executing the command.
sleep "$TOTAL_DELAY"

# Execute the action based on the mode.
if [ "$MODE" = "reboot" ]; then
  echo "Rebooting now..."
  # Using 'sudo' to ensure necessary privileges.
  sudo systemctl reboot
elif [ "$MODE" = "shutdown" ]; then
  echo "Shutting down now..."
  # 'poweroff' is commonly used for shutdown.
  sudo systemctl poweroff
fi
#!/bin/bash
###############################################################################
# schedule_power.sh
#
# This script schedules either a system reboot or a shutdown after a
# specified delay. The delay can be provided in hours, minutes, and seconds.
#
# Usage: ./schedule_power.sh [-r|-s] [-H hours] [-M minutes] [-S seconds]
#
# Options:
#   -r           Schedule a reboot.
#   -s           Schedule a shutdown.
#   -H hours     Set the delay in hours (default: 0).
#   -M minutes   Set the delay in minutes (default: 0).
#   -S seconds   Set the delay in seconds (default: 0).
#   -h           Display this help message and exit.
#
# Examples:
#   ./schedule_power.sh -r -H 0 -M 20 -S 0
#       Schedules a reboot in 20 minutes.
#
# Author: [Your Name]
# Date: [Today's Date]
###############################################################################

# Function to display the usage/help message.
usage() {
  cat <<EOF
Usage: $(basename "$0") [-r|-s] [-H hours] [-M minutes] [-S seconds]
       -r           Schedule a reboot.
       -s           Schedule a shutdown.
       -H hours     Delay in hours (default 0).
       -M minutes   Delay in minutes (default 0).
       -S seconds   Delay in seconds (default 0).
       -h           Show this help message.
Example:
       $(basename "$0") -r -H 0 -M 20 -S 0
       This schedules a reboot in 20 minutes.
EOF
}

# Initialize default values for the time parameters.
MODE=""
HOURS=0
MINUTES=0
SECONDS=0

# Parse command-line options using getopts.
while getopts "rsH:M:S:h" opt; do
  case "$opt" in
    r)
      if [ -n "$MODE" ]; then
        echo "Error: Only one mode (-r or -s) may be specified." >&2
        usage
        exit 1
      fi
      MODE="reboot"
      ;;
    s)
      if [ -n "$MODE" ]; then
        echo "Error: Only one mode (-r or -s) may be specified." >&2
        usage
        exit 1
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
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

# Ensure that a mode was specified.
if [ -z "$MODE" ]; then
  echo "Error: You must specify either -r for reboot or -s for shutdown." >&2
  usage
  exit 1
fi

# Validate that the time inputs are non-negative integers.
if ! [[ "$HOURS" =~ ^[0-9]+$ ]] || ! [[ "$MINUTES" =~ ^[0-9]+$ ]] || ! [[ "$SECONDS" =~ ^[0-9]+$ ]]; then
  echo "Error: Hours, minutes, and seconds must be non-negative integers." >&2
  usage
  exit 1
fi

# Calculate the total delay in seconds.
TOTAL_DELAY=$(( HOURS * 3600 + MINUTES * 60 + SECONDS ))
if [ "$TOTAL_DELAY" -le 0 ]; then
  echo "Error: Total delay must be greater than 0 seconds." >&2
  usage
  exit 1
fi

# Provide feedback about the scheduled action.
echo "Scheduling ${MODE} in ${HOURS} hour(s), ${MINUTES} minute(s), and ${SECONDS} second(s)..."
echo "Total delay: ${TOTAL_DELAY} second(s)."

# Sleep for the total computed delay before executing the command.
sleep "$TOTAL_DELAY"

# Execute the action based on the mode.
if [ "$MODE" = "reboot" ]; then
  echo "Rebooting now..."
  # Using 'sudo' to ensure necessary privileges.
  sudo systemctl reboot
elif [ "$MODE" = "shutdown" ]; then
  echo "Shutting down now..."
  # 'poweroff' is commonly used for shutdown.
  sudo systemctl poweroff
fi

