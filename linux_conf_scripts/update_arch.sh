#!/usr/bin/env bash

set -euo pipefail

# Default behavior if no arguments for reboot or shutdown are given
PROMPT_ACTION="true"

REBOOT_TIME="now"
SHUTDOWN_TIME="now"
DO_REBOOT="false"
DO_SHUTDOWN="false"
KEEP_GOING="false"

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --reboot [minutes|now]      Schedule a reboot after the script finishes.
                              If no time is given, defaults to 'now'.
  --shutdown [minutes|now]    Schedule a shutdown after the script finishes.
                              If no time is given, defaults to 'now'.
  --keep-going                Skip interactive prompts if no reboot or shutdown specified.
  -h, --help                  Show this help message.

If neither --reboot nor --shutdown is specified, the script will prompt the user
to choose an action. Specifying --keep-going prevents the prompt, and the script
will exit without rebooting or shutting down.
EOF
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --reboot)
            DO_REBOOT="true"
            PROMPT_ACTION="false"
            if [[ ${2:-} && ! $2 =~ ^- ]]; then
                REBOOT_TIME=$2
                shift
            fi
            shift
            ;;
        --shutdown)
            DO_SHUTDOWN="true"
            PROMPT_ACTION="false"
            if [[ ${2:-} && ! $2 =~ ^- ]]; then
                SHUTDOWN_TIME=$2
                shift
            fi
            shift
            ;;
        --keep-going)
            KEEP_GOING="true"
            PROMPT_ACTION="false"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Ensure that both reboot and shutdown are not requested simultaneously
if [[ "$DO_REBOOT" == "true" && "$DO_SHUTDOWN" == "true" ]]; then
    echo "Error: You cannot specify both --reboot and --shutdown."
    exit 1
fi

update_keyring() {
    echo "==> Initializing and refreshing pacman keyring..."
    sudo pacman-key --init
    sudo pacman-key --populate archlinux
    sudo pacman-key --refresh-keys || echo "Warning: Some keys may not have been refreshed."
}

system_update() {
    echo "==> Updating system packages via pacman..."
    sudo pacman -Syyu --noconfirm
}

update_boot() {
    echo "==> Rebuilding initramfs..."
    sudo mkinitcpio -P

    echo "==> Updating grub configuration..."
    sudo grub-mkconfig -o /boot/grub/grub.cfg
}

aur_update() {
    echo "==> Updating AUR packages via yay..."
    yay -Syyuu --devel --batchinstall --asdeps --sudoloop --noconfirm || echo "Warning: AUR update may have failed on some packages."
}

prompt_for_action() {
    local choice
    echo "No reboot or shutdown argument provided."
    if [[ "$KEEP_GOING" == "true" ]]; then
        echo "--keep-going was specified, skipping prompt. Exiting without reboot/shutdown."
        return
    fi

    echo "What would you like to do?"
    echo "1) Reboot now"
    echo "2) Shutdown now"
    echo "3) Nothing, exit script"
    read -rp "Enter choice [1-3]: " choice

    case "$choice" in
        1)
            DO_REBOOT="true"
            REBOOT_TIME="now"
            ;;
        2)
            DO_SHUTDOWN="true"
            SHUTDOWN_TIME="now"
            ;;
        3)
            DO_REBOOT="false"
            DO_SHUTDOWN="false"
            ;;
        *)
            echo "Invalid choice. Exiting without reboot/shutdown."
            ;;
    esac
}

perform_action() {
    if [[ "$DO_REBOOT" == "true" ]]; then
        if [[ "$REBOOT_TIME" == "now" ]]; then
            echo "Rebooting now..."
            sudo shutdown -r now
        else
            echo "Scheduling reboot in $REBOOT_TIME minutes..."
            sudo shutdown -r +"$REBOOT_TIME"
        fi
    elif [[ "$DO_SHUTDOWN" == "true" ]]; then
        if [[ "$SHUTDOWN_TIME" == "now" ]]; then
            echo "Shutting down now..."
            sudo shutdown -h now
        else
            echo "Scheduling shutdown in $SHUTDOWN_TIME minutes..."
            sudo shutdown -h +"$SHUTDOWN_TIME"
        fi
    else
        echo "No reboot or shutdown scheduled. Exiting."
    fi
}

# Main script execution
update_keyring
system_update
update_boot
aur_update

if [[ "$PROMPT_ACTION" == "true" ]]; then
    prompt_for_action
fi

perform_action
