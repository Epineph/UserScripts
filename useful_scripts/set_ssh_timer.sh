#!/usr/bin/env bash
#
# set_ssh_timer - Start an SSH agent and add your key with a limited lifetime.
#
# IMPORTANT:
#   To update your current shell with the SSH agent's environment variables,
#   run this script using eval, for example:
#
#       eval "$(./set_ssh_timer -t 2M)"
#
# OPTIONS:
#   -t, --timeout <duration>  Set the lifetime of the key. For example:
#                             "120" (seconds), "2m" (2 minutes), "2h" (2 hours).
#   -k, --key <key_file>      Specify which SSH key to add (defaults to ~/.ssh/id_rsa).
#   -h, --help                Display this help message.

usage() {
  cat <<EOF
Usage: $(basename "$0") -t <timeout> [-k <key_file>] [--help]

This script starts an SSH agent (if needed) and adds an SSH key with a time-limited lifetime.
The key will be removed from the agent after the specified timeout.

Options:
  -t, --timeout <duration>  Set the lifetime for the key (e.g., "120", "2m", "2h").
  -k, --key <key_file>      Specify the SSH key to add (default: \$HOME/.ssh/id_rsa).
  -h, --help                Display this help message.

NOTE:
  To update your current shell with the agent's environment,
  run this command as:
      eval "\$(./$(basename "$0") -t <timeout> [-k <key_file>])"
EOF
}

error_exit() {
  echo "Error: $1" >&2
  usage
  exit 1
}

TIMEOUT=""
KEY=""

# Parse command-line options.
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--timeout)
      if [[ -n "$2" ]]; then
        TIMEOUT="$2"
        shift 2
      else
        error_exit "Option '$1' requires a timeout argument."
      fi
      ;;
    -k|--key)
      if [[ -n "$2" ]]; then
        KEY="$2"
        shift 2
      else
        error_exit "Option '$1' requires a key file argument."
      fi
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      error_exit "Unknown option: $1"
      ;;
    *)
      break
      ;;
  esac
done

# Set default key if not provided.
if [[ -z "$KEY" ]]; then
  KEY="$HOME/.ssh/id_rsa"
fi

# Check that the key file exists.
if [[ ! -f "$KEY" ]]; then
  error_exit "Key file '$KEY' does not exist."
fi

# Set a default timeout if not provided.
if [[ -z "$TIMEOUT" ]]; then
  TIMEOUT="3600"
fi

# Check if an SSH agent is already running.
if [[ -n "$SSH_AGENT_PID" ]] && ssh-add -l >/dev/null 2>&1; then
  echo "# Using already running ssh-agent." >&2
else
  # Start a new SSH agent.
  eval "$(ssh-agent -s)" || error_exit "Failed to start ssh-agent."
  echo "# Started new ssh-agent." >&2
fi

# Add the SSH key with the specified lifetime.
ssh-add -t "${TIMEOUT}" "${KEY}" || error_exit "Failed to add key '$KEY' with timeout '${TIMEOUT}'."

# Inform the user; note that TIMEOUT value processing (e.g., "2M") depends on ssh-add.
echo "# Added key '$KEY' with a timeout of ${TIMEOUT}."
echo "export SSH_AUTH_SOCK=${SSH_AUTH_SOCK};"
echo "export SSH_AGENT_PID=${SSH_AGENT_PID};"

