#!/usr/bin/env bash
set -euo pipefail

#------------------------------#
#  setup-hover-width.sh        #
#------------------------------#
HYPER_CONFIG="${HOME}/.config/hypr/hyprland.conf"
SCRIPT_DIR="${HOME}/.config/hypr/scripts"
SCRIPT_PATH="${SCRIPT_DIR}/hover-width.sh"
KEY_COMBO='$mainMod SHIFT_L CTRL, W'
BIND_LINE="bind = ${KEY_COMBO}, exec, ~/.config/hypr/scripts/hover-width.sh"

function show_help() {
	local pager
	pager="${HELP_PAGER:-less -R}"

	if ! command -v less >/dev/null 2>&1 &&
		[ "$pager" = "less -R" ]; then
		pager="cat"
	fi

	"$pager" <<'EOF'
setup-hover-width.sh
--------------------

Idempotently install a Hyprland helper script that shows the width of the
window under the mouse cursor via `hyprctl notify`, and append a keybinding
to your Hyprland config if it is not already present.

Defaults:
  Script path : ~/.config/hypr/scripts/hover-width.sh
  Config file : ~/.config/hypr/hyprland.conf
  Key binding : bind = $mainMod SHIFT_L CTRL, W, exec, ~/.config/hypr/scripts/hover-width.sh
Usage:
  setup-hover-width.sh           Install script and binding.
  setup-hover-width.sh --force   Rewrite helper script.
  setup-hover-width.sh -h|--help Show this help.

You may edit KEY_COMBO and BIND_LINE at the top of the script if you prefer
another key combination.
EOF
}

function ensure_jq_pkg() {
	local missing_packages=()

	if ! command -v jq >/dev/null 2>&1; then
		echo -e "Error: potetential missing package!\n
		Note: the command 'jq' was not found"
		echo -e "To show the width of the window currently under the cursor\n
		in a Hyprland notification requires the package: ̈́'jq'.\n
		The command hyprctl is also requires"

		# Extra check
		if ! pacman -Qi "$package" &>/dev/null; then
			missing_packages+=("$package")
		else
			echo "Package '$package' is already installed."
		fi

		# If there are missing packages, ask the user if they want to install them
		if [ ${#missing_packages[@]} -ne 0 ]; then
			echo "The following packages are not installed: ${missing_packages[*]}"
			read -p "Do you want to install them? (Y/n) " -n 1 -r
			echo
			if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
				yes | sudo pacman -S "$package"
				if [ $? -ne 0 ]; then
					echo "Failed to install $package. Aborting."
					exit 1
				fi
			else
				echo "The following packages are required to continue:\
    			${missing_packages[*]}. Aborting."
				exit 1
			fi
		fi
	fi
}

function ensure_helper_script() {
	mkdir -p "$SCRIPT_DIR"

	if [ -f "$SCRIPT_PATH" ] && [ "$FORCE_REWRITE" -eq 0 ]; then
		return 0
	fi

	cat >"$SCRIPT_PATH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# hover-width.sh
# Show the width of the window currently under the cursor in a Hyprland
# notification. Requires `jq` and `hyprctl`.

if ! command -v jq >/dev/null 2>&1; then
  hyprctl notify 0 5000 "rgb(f38ba8)" \
    "hover-width: jq is not installed."
  exit 1
fi

width="$(
  hyprctl -j clients | \
  jq -r --argjson c "$(hyprctl -j cursorpos)" '
    .[] | select(
      ($c.x >= .at[0] and $c.x <= (.at[0] + .size[0])) and
      ($c.y >= .at[1] and $c.y <= (.at[1] + .size[1]))
    ) | .size[0]
  '
)"

if [ -n "${width}" ] && [ "${width}" != "null" ]; then
  hyprctl notify 0 5000 "rgb(89b4fa)" \
    "Window width under cursor: ${width}px"
else
  hyprctl notify 0 5000 "rgb(f38ba8)" \
    "hover-width: no window under cursor."
fi
EOF

	chmod +x "$SCRIPT_PATH"
}

function ensure_binding() {
	if [ ! -f "$HYPER_CONFIG" ]; then
		printf 'Hyprland config not found: %s\n' "$HYPER_CONFIG" >&2
		exit 1
	fi

	if grep -Fq 'hover-width.sh' "$HYPER_CONFIG"; then
		return 0
	fi

	{
		printf '\n'
		printf '# Show width of window under cursor\n'
		printf '%s\n' "$BIND_LINE"
	} >>"$HYPER_CONFIG"
}

FORCE_REWRITE=0

if [ "${#}" -gt 0 ]; then
	case "${1}" in
	-h | --help)
		show_help
		exit 0
		;;
	--force)
		FORCE_REWRITE=1
		;;
	*)
		printf 'Unknown option: %s\n' "${1}" >&2
		printf 'Use --help for usage.\n' >&2
		exit 1
		;;
	esac
fi

ensure_jq_pkg
ensure_helper_script
ensure_binding

printf 'hover-width helper installed.\n'
printf 'Script : %s\n' "$SCRIPT_PATH"
printf 'Config : %s\n' "$HYPER_CONFIG"
printf 'Binding: %s\n' "$BIND_LINE"
printf 'Reload Hyprland (hyprctl reload) to apply the binding.\n'
