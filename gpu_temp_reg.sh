#!/bin/bash

# Define paths
SCRIPT_PATH="/usr/local/bin/cputemp_regulator.sh"
SERVICE_PATH="/etc/systemd/system/cputemp_regulator.service"

# Write the CPU temperature regulation script
cat << 'EOF' > "$SCRIPT_PATH"
#!/bin/bash
# Define temperature thresholds and frequency settings
TEMP_HIGH=90
TEMP_MEDIUM=85
TEMP_LOW=70
FREQ_HIGH="3.4GHz"
FREQ_MEDIUM="2.8GHz"
FREQ_LOW="2.4GHz"
FREQ_MIN="1.6GHz"
HYSTERESIS=2
NUM_SAMPLES=5
SLEEP_INTERVAL=5
LOG_FILE="/var/log/cputemp_regulator.log"
TEMP_SAMPLES=()

function calculate_average_temp {
    local sum=0
    for temp in "${TEMP_SAMPLES[@]}"; do
        sum=$(echo "$sum + $temp" | bc)
    done
    echo "scale=1; $sum / ${#TEMP_SAMPLES[@]}" | bc
}

while true; do
    CUR_TEMP=$(sensors | grep -m 1 'Package id 0:' | awk '{print $4}' | sed 's/+//g' | sed 's/°C//g')
    TEMP_SAMPLES+=("$CUR_TEMP")
    if [ ${#TEMP_SAMPLES[@]} -gt $NUM_SAMPLES ]; then
        TEMP_SAMPLES=("${TEMP_SAMPLES[@]:1}")
    fi
    AVG_TEMP=$(calculate_average_temp)
    if (( $(echo "$AVG_TEMP >= $TEMP_HIGH" | bc -l) )); then
        sudo cpupower frequency-set -u $FREQ_MIN
        echo "[$(date)] WARNING: CPU temperature ($AVG_TEMP°C) too high! Reducing to $FREQ_MIN" >> "$LOG_FILE"
    else
        sudo cpupower frequency-set -u $FREQ_HIGH
        echo "[$(date)] INFO: CPU temperature ($AVG_TEMP°C) normal. Frequency at $FREQ_HIGH" >> "$LOG_FILE"
    fi
    sleep $SLEEP_INTERVAL
done
EOF

# Make the script executable
chmod +x "$SCRIPT_PATH"

# Create systemd service unit file
cat << EOF > "$SERVICE_PATH"
[Unit]
Description=CPU Temperature Regulation
After=network.target

[Service]
Type=simple
ExecStart=$SCRIPT_PATH
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd, start and enable the service
systemctl daemon-reload
systemctl start cputemp_regulator.service
systemctl enable cputemp_regulator.service

echo "Service cputemp_regulator has been installed and started."

