#!/bin/bash

# Paths
ZSH_FUNCTIONS="$HOME/.zsh_profile/.zsh_functions.zsh"
SSH_MONITOR_SCRIPT="/usr/local/bin/ssh_passphrase_monitor.sh"
SYSTEMD_SERVICE="/etc/systemd/system/ssh-passphrase-monitor.service"
SSH_LOG="$HOME/.ssh/ssh-agent.log"

# ssh-add function to add
SSH_FUNCTION="
# Wrapper function for ssh-add
ssh-add() {
  # Redirect stderr to a custom log
  command ssh-add \"\$@\" 2>>$SSH_LOG

  # Preserve the original exit status
  local status=\$?

  # Return the status
  return \$status
}
"

# 1. Check and add the ssh-add function to .zsh_functions.zsh
if ! grep -q "ssh-add()" "$ZSH_FUNCTIONS"; then
  echo "Adding ssh-add wrapper function to $ZSH_FUNCTIONS..."
  sed -i "2i\\
$SSH_FUNCTION\\
" "$ZSH_FUNCTIONS"
else
  echo "ssh-add function already exists in $ZSH_FUNCTIONS."
fi

# 2. Create the SSH passphrase monitor script
echo "Creating SSH passphrase monitor script at $SSH_MONITOR_SCRIPT..."
cat << 'EOF' | sudo tee "$SSH_MONITOR_SCRIPT" > /dev/null
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
EOF

# Make the script executable
sudo chmod +x "$SSH_MONITOR_SCRIPT"

# 3. Create the systemd service
echo "Creating systemd service at $SYSTEMD_SERVICE..."
cat << EOF | sudo tee "$SYSTEMD_SERVICE" > /dev/null
[Unit]
Description=Monitor SSH passphrase prompts and trigger a timer
After=network.target

[Service]
ExecStart=$SSH_MONITOR_SCRIPT
Restart=always
User=$USER
Environment=HOME=$HOME

[Install]
WantedBy=multi-user.target
EOF

# Reload and enable the systemd service
echo "Reloading systemd and enabling the service..."
sudo systemctl daemon-reload
sudo systemctl enable ssh-passphrase-monitor.service
sudo systemctl start ssh-passphrase-monitor.service

# 4. Reload the .zshrc file
echo "Reloading .zshrc to include updated functions..."
source "$HOME/.zshrc"

# Final message
echo "Setup complete! The SSH passphrase monitor is now active."

