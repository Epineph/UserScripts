#!/bin/bash
################################################################################
# setup_full_ssh_monitor.sh
#
# 1) Creates/Overwrites a wrapper script for `ssh-add`, which logs a line
#    "Enter passphrase for key '/home/USER/.ssh/id_rsa':" to ~/.ssh/ssh-agent.log
#    before calling the real ssh-add.
#
# 2) Creates/Overwrites a monitor script that tails ~/.ssh/ssh-agent.log and
#    triggers a single-keystroke custom timer prompt whenever it sees the above line.
#
# 3) Installs a systemd service that runs this monitor continuously.
#
# 4) Overwrites any existing scripts or services with the same name/paths.
#
# NOTE: Because it's installed as a systemd service, any interactive prompts won't
#       appear in your regular terminal session. If you'd like to see the prompt
#       in real time, you must run the monitor script in the foreground or use
#       a user-level systemd service that attaches to your session.
################################################################################

###############################################################################
# 0) Variables and Paths
###############################################################################
WRAPPER_SCRIPT="/usr/local/bin/ssh-add-wrapper"
MONITOR_SCRIPT="/usr/local/bin/ssh_passphrase_monitor.sh"
SYSTEMD_SERVICE="/etc/systemd/system/ssh-passphrase-monitor.service"

# This is the exact passphrase line we'll log and monitor for:
# Make sure it matches the path to your key exactly!
TRIGGER_PHRASE="Enter passphrase for key '/home/$USER/.ssh/id_rsa':"

# Default timer in seconds
DEFAULT_TIMER=3600

# Location of the ssh-agent log we’ll tail
LOG_FILE="$HOME/.ssh/ssh-agent.log"

###############################################################################
# 1) Create/Overwrite the ssh-add Wrapper
###############################################################################
echo "1) Installing (overwriting) the ssh-add wrapper at: $WRAPPER_SCRIPT"

# The wrapper logs the "Enter passphrase" line to the log file, then calls real ssh-add.
sudo tee "$WRAPPER_SCRIPT" >/dev/null << EOF
#!/bin/bash
################################################################################
# ssh-add-wrapper
#
# Logs a "Enter passphrase..." line to ~/.ssh/ssh-agent.log so we can detect
# the passphrase prompt with our monitor script. Then calls the real ssh-add.
################################################################################

LOGFILE="$LOG_FILE"

# Last argument is typically the path to the key, but we'll allow any usage.
# We won't parse arguments in detail, just echo the line for your .ssh/id_rsa if found.
# If you have multiple keys, you might generalize this approach.
KEY_PATH="\${@: -1}"

# If the user is calling e.g. `ssh-add -l` with no key path,
# there's no passphrase prompt. We'll only log if we see something that
# looks like a key under /home/$USER/.ssh.
if [[ "\$KEY_PATH" =~ ^/home/$USER/.ssh/.* ]]; then
  echo "$TRIGGER_PHRASE" >> "\$LOGFILE"
fi

# Now run the real ssh-add, capturing stderr to the log so we see "Identity added" lines, etc.
command /usr/bin/ssh-add "\$@" 2>>"\$LOGFILE"
EOF

# Make it executable
sudo chmod +x "$WRAPPER_SCRIPT"

###############################################################################
# 2) Tell the Shell to Use Our Wrapper
###############################################################################
# We'll add a function or alias to .zshrc/.bashrc so that when you run `ssh-add`,
# it calls the wrapper. We'll check if it's already present, and add it if not.
SHELL_RC="$HOME/.zshrc"   # or "$HOME/.bashrc" if you use Bash by default

# We'll only do this if the user is missing the override
if ! grep -q "ssh-add-wrapper" "$SHELL_RC" 2>/dev/null; then
  echo "Overriding 'ssh-add' in $SHELL_RC to use $WRAPPER_SCRIPT..."
  echo -e "\n# Force ssh-add to go through our wrapper\nssh-add() {\n  $WRAPPER_SCRIPT \"\$@\"\n}\n" >> "$SHELL_RC"
else
  echo "ssh-add wrapper already referenced in $SHELL_RC. Skipping."
fi

###############################################################################
# 3) Create/Overwrite the Monitor Script
###############################################################################
echo "3) Installing (overwriting) the monitor script at: $MONITOR_SCRIPT"

sudo tee "$MONITOR_SCRIPT" >/dev/null << EOF
#!/bin/bash
################################################################################
# ssh_passphrase_monitor.sh
#
# Monitors ~/.ssh/ssh-agent.log for the line:
#   "Enter passphrase for key '/home/$USER/.ssh/id_rsa':"
# Once we see it, we prompt for either a custom or default timer, then sleep.
#
# Installed as a systemd service, this runs in the background. However, systemd
# typically has no interactive TTY, so you won't actually see or respond to the
# prompt in a normal terminal. It's here primarily as a demonstration.
################################################################################

# The line we look for in the log:
TRIGGER_PHRASE="$TRIGGER_PHRASE"

# Default timer value in seconds
DEFAULT_TIMER=$DEFAULT_TIMER

# Ensure the log file exists
touch "$LOG_FILE"

###############################################################################
# Function: run_timer
# Sleeps for the provided number of seconds, printing start/finish messages.
###############################################################################
run_timer() {
  local duration="\$1"
  echo "Timer started for \$duration seconds."
  sleep "\$duration"
  echo "Timer finished."
}

###############################################################################
# Function: prompt_for_custom_timer
# Single-keystroke prompt for custom (y) or default (n) timer
###############################################################################
prompt_for_custom_timer() {
  echo -n "Use custom timer? [y/n]: "

  # Attempt to read a single key without Enter. 
  # This won't work in typical systemd usage (no TTY).
  stty -echo -icanon time 0 min 0
  local char=""
  while : ; do
    char="\$(dd bs=1 count=1 2>/dev/null)"
    if [[ "\$char" =~ [yYnN] ]]; then
      break
    fi
  done
  # Restore terminal settings
  stty sane

  echo "\$char"

  if [[ "\$char" =~ [yY] ]]; then
    echo -n "Enter custom duration (seconds): "
    read -r custom_duration
    if [[ "\$custom_duration" =~ ^[0-9]+\$ ]]; then
      run_timer "\$custom_duration"
    else
      echo "Invalid input. Using default \$DEFAULT_TIMER."
      run_timer "\$DEFAULT_TIMER"
    fi
  else
    run_timer "\$DEFAULT_TIMER"
  fi
}

###############################################################################
# Main Monitoring Loop
###############################################################################
tail -F "$LOG_FILE" | while read -r line; do
  if [[ "\$line" == *"\$TRIGGER_PHRASE"* ]]; then
    echo "Detected passphrase prompt in the log. Triggering timer logic..."
    prompt_for_custom_timer
  fi
done
EOF

sudo chmod +x "$MONITOR_SCRIPT"

###############################################################################
# 4) Create/Overwrite the systemd Service
###############################################################################
echo "4) Installing (overwriting) $SYSTEMD_SERVICE"
sudo tee "$SYSTEMD_SERVICE" >/dev/null << EOF
[Unit]
Description=Monitor SSH passphrase prompts (via wrapper logging) and trigger a timer
After=network.target

[Service]
ExecStart=$MONITOR_SCRIPT
Restart=always
User=$USER
Environment=HOME=$HOME

[Install]
WantedBy=multi-user.target
EOF

###############################################################################
# 5) Enable & Start the Service
###############################################################################
echo "5) Reloading systemd, enabling, and starting the ssh-passphrase-monitor service..."
sudo systemctl daemon-reload
sudo systemctl enable ssh-passphrase-monitor.service
sudo systemctl restart ssh-passphrase-monitor.service

###############################################################################
# Done!
###############################################################################
cat <<DONE

--------------------------------------------------------------------------------
Setup complete!

1. We installed (overwrote) $WRAPPER_SCRIPT:
   - Logs the "Enter passphrase..." line before calling real ssh-add.

2. We updated your shell config ($SHELL_RC) so "ssh-add" calls the wrapper.

3. We installed (overwrote) $MONITOR_SCRIPT:
   - Looks for "$TRIGGER_PHRASE" in $LOG_FILE
   - Prompts for a timer (which won't be visible in normal systemd usage).

4. We created/overwrote $SYSTEMD_SERVICE, which:
   - Runs the monitor in the background.
   - Will attempt a single-keystroke prompt on detection,
     but there's no interactive TTY in typical systemd usage.

If you want truly interactive prompts, run:
   $MONITOR_SCRIPT
in your own terminal, *not* as a systemd service.

Check status:
   systemctl status ssh-passphrase-monitor.service

Check logs:
   journalctl -u ssh-passphrase-monitor.service -f

Enjoy!
--------------------------------------------------------------------------------
DONE

