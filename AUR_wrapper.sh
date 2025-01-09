#!/usr/bin/env bash

# A wrapper for yay with normal and silent modes, handling failures gracefully.

# Default paths for output
FINAL_COMMAND_SCRIPT="$HOME/final-command.sh"
FINAL_COMMAND_TEXT="$HOME/final-command.txt"

# Ensure yay is installed
if ! command -v yay >/dev/null; then
  echo "Error: 'yay' command not found. Please install yay first." >&2
  exit 1
fi

###############################################################################
# Functions
###############################################################################

# Function to display usage
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] -- yay <yay-arguments>

Options:
  --silent        Run yay silently after failure.
  --install       Automatically install if ready after silent run.
  --help          Show this help message and exit.

Examples:
  # Run yay normally
  ./enhanced-yay.sh -- yay -S package1 package2

  # Run silently after failure
  ./enhanced-yay.sh --silent -- yay -S package1 package2

  # Run silently and auto-install
  ./enhanced-yay.sh --silent --install -- yay -S package1 package2
EOF
}

# Function to send notification
send_notification() {
  local status="$1"
  if command -v notify-send >/dev/null; then
    if [[ "$status" -eq 0 ]]; then
      notify-send "yay" "Installation completed successfully!" --urgency=low
    else
      notify-send "yay" "Installation failed!" --urgency=critical
    fi
  fi
}

# Function to write final command
write_final_command() {
  echo "#!/usr/bin/env bash" > "$FINAL_COMMAND_SCRIPT"
  echo "$1" >> "$FINAL_COMMAND_SCRIPT"
  chmod +x "$FINAL_COMMAND_SCRIPT"

  echo "$1" > "$FINAL_COMMAND_TEXT"
  echo "Final command written to:"
  echo "  $FINAL_COMMAND_SCRIPT (executable)"
  echo "  $FINAL_COMMAND_TEXT (plain text)"
}

# Function to clean yay cache
clean_cache() {
  yay -Sc --noconfirm >/dev/null 2>&1
}

###############################################################################
# Parse Arguments
###############################################################################

SILENT_MODE=false
AUTO_INSTALL=false

# Parse options
while [[ $# -gt 0 ]]; do
  case "$1" in
    --silent)
      SILENT_MODE=true
      shift
      ;;
    --install)
      AUTO_INSTALL=true
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

# The remaining arguments are the actual yay command
if [[ $# -eq 0 ]]; then
  echo "Error: No yay command provided."
  usage
  exit 1
fi

###############################################################################
# Run Command
###############################################################################

# Build the full command string
YAY_COMMAND="yay $*"

if [[ "$SILENT_MODE" == false ]]; then
  echo "Running normally: $YAY_COMMAND"
  if ! $YAY_COMMAND; then
    echo "Command failed. Re-run in silent mode with:"
    echo "  $(basename "$0") --silent -- $YAY_COMMAND"
    exit 1
  fi
else
  echo "Running silently: $YAY_COMMAND"
  (
    # Suppress output and redirect to a log file
    $YAY_COMMAND >/dev/null 2>&1
  )
  STATUS=$?

  # Clean cache
  clean_cache

  # Notify user
  send_notification "$STATUS"

  if [[ "$STATUS" -eq 0 ]]; then
    echo "Silent run successful!"
    write_final_command "$YAY_COMMAND"

    if [[ "$AUTO_INSTALL" == true ]]; then
      echo "Auto-installing with final command..."
      $YAY_COMMAND
    else
      echo "Final command is ready in $FINAL_COMMAND_SCRIPT or $FINAL_COMMAND_TEXT."
    fi
  else
    echo "Silent run failed. Check logs for details."
    exit 1
  fi
fi

