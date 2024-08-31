#!/bin/bash

dir="$XDG_CONFIG_HOME/bash_completion"

if [[ ! -f "$dir" ]]; then
	sudo mkdir -p "$dir"
fi

sudo rg --gerate complete-bash > "$dir/rg.bash"
