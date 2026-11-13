#!/usr/bin/env bash

# Script to hide the current focused window, run a long command, and restore the window

# === CONFIGURABLE ===
HIDE_WORKSPACE=99  # A rarely used workspace number to "hide" the window
RETURN_WORKSPACE="$(hyprctl activeworkspace -j | jq '.id')"  # Save current workspace
CMD="$@"  # Command to run while window is hidden

# === Identify the focused window ===
FOCUSED_WIN="$(hyprctl activewindow -j | jq -r '.address')"
[[ -z "$FOCUSED_WIN" || "$FOCUSED_WIN" == "null" ]] && {
    echo "No focused window found."
    exit 1
}

# === Move window to the hidden workspace ===
hyprctl dispatch movetoworkspace "$HIDE_WORKSPACE,address:$FOCUSED_WIN"

# === Run the command ===
eval "$CMD"

# === Return the window to original workspace ===
hyprctl dispatch movetoworkspace "$RETURN_WORKSPACE,address:$FOCUSED_WIN"
hyprctl dispatch workspace "$RETURN_WORKSPACE"

