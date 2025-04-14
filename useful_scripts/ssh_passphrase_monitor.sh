#!/bin/bash

# Define the phrase to monitor
TRIGGER_PHRASE="Enter passphrase for key '/home/heini/.ssh/id_rsa':"
DEFAULT_TIMER=3600  # Default timer duration in seconds

# Ensure the log file exists
touch "$HOME/.ssh/ssh-agent.log"

# Monitor the log for the trigger phrase
tail -F "$HOME/.ssh/ssh-agent.log" | while read -r line; do
  if [[ "$line" == *"$TRIGGER_PHRASE"* ]]; then
    echo "Passphrase prompt detected! Starting timer for $DEFAULT_TIMER seconds."
    sleep $DEFAULT_TIMER
    echo "Timer finished."
  fi
done
