#!/bin/bash

# Helper script to enable and start services
enable_service_script="/tmp/enable_service.sh"
cat <<EOF >"$enable_service_script"
#!/bin/bash
# Process each service passed as an argument
for service in "\$@"
do
    # Resolve symlinks to their real targets
    real_service_path=\$(readlink -f "\$service")
    real_service_name=\$(basename "\$real_service_path")
    
    echo "Enabling \${real_service_name}..."
    sudo systemctl enable "\$real_service_name"
    sudo systemctl start "\$real_service_name"
done
EOF
chmod +x "$enable_service_script"

# Find and select services
selected_services=$(find /etc/systemd/system /usr/lib/systemd/system -type f -name "*.service" -or -type l | \
    fzf --multi --preview 'bat --color=always --style=grid --line-range :500 {}' --preview-window=down:70%:wrap \
        --bind 'tab:toggle+down' --bind 'shift-tab:toggle+up' --bind 'enter:accept')

# Check if any services were selected
if [ -n "$selected_services" ]; then
    # Call the enable_service_script with all selected services
    echo "$selected_services" | xargs -d '\n' -n 1 "$enable_service_script"
else
    echo "No services selected."
fi

