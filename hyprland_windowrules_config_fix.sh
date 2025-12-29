#!/usr/bin/env bash

cd ~/.config/hypr/UserConfigs || exit 1

cp -av WindowRules.conf "WindowRules.conf.bak.$(date +%F_%H%M%S)"

cat >WindowRules.conf <<'EOF'
windowrule = opacity 0.8 0.7, match:tag terminal*
windowrule = opacity 0.9 0.7, match:tag browser*
windowrule = workspace 1, match:tag email*
windowrule = workspace 2, match:tag browser*
windowrule = workspace 4 silent, match:tag screenshare*
windowrule = workspace 5, match:tag gamestore*
windowrule = workspace 6 silent, match:class ^(\.virt-manager-wrapped)$
windowrule = workspace 6 silent, match:class ^(virt-manager)$
windowrule = workspace 7, match:tag im*
windowrule = workspace 8, match:tag games*
windowrule = workspace 9 silent, match:tag multimedia*
EOF

hyprctl reload
hyprctl configerrors
