#!/bin/bash

# Helper script to enable and start services
enable_service_script="/tmp/enable_service.sh"
cat <<EOF >"$enable_service_script"
#!/bin/bash
service="\$1"
echo "Enabling \${service}..."
sudo systemctl enable "\$service"
sudo systemctl start "\$service"
EOF
chmod +x "$enable_service_script"

# Use find to search for .service files and handle execution directly
find /etc/systemd/system /usr/lib/systemd/system -type f -name "*.service" -or -type l | \
    fzf --multi --preview 'bat --color=always --style=grid --line-range :500 {}' --preview-window=down:70%:wrap \
        --bind 'tab:toggle+down' --bind 'shift-tab:toggle+up' \
        --bind 'enter:execute(echo {} | xargs -n 1 basename | xargs -I{} '$enable_service_script' {})+abort' | \
    xargs -n 1 basename | xargs -I{} "$enable_service_script" {}


