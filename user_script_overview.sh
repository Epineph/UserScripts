#!/bin/bash

REPO_DIR="$HOME/repos/UserScripts"
USER_SCRIPTS_OVERVIEW="$(lsd -a -l -F -Z -t -X --color=always --group-directories-first -h --tree --depth 2  "$REPO_DIR")"

sudo touch "$REPO_DIR"/user_script_overview.md

echo '#!/bin/bash' > "$REPO_DIR"/user_script_overview.md


echo -e "\n\n\n$USER_SCRIPTS_OVERVIEW" | sudo tee -a "$REPO_DIR"/user_script_overview.md

