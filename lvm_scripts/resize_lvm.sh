#!/usr/bin/env bash

set -euo pipefail

# Function to show help section
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -h, --help                   Show this help message.
  -r, --resize                 Enter interactive resize mode.

Description:
This script displays and manages LVM logical volumes. It allows you to resize 
volumes (shrink or extend) interactively. Shrinking requires another volume to be extended 
to maintain space balance.

IMPORTANT:
If you need to unmount logical volumes for resizing, this script must be run from an 
Arch Linux ISO or another live environment where volumes can be safely unmounted.

Steps performed:
1. Displays logical volumes with their sizes.
2. Allows selection of a volume for resizing.
3. Provides options to shrink or extend the selected volume.
4. Ensures space balance by shrinking one volume and extending another.

Dependencies:
- lvm2
- fzf (for interactive selection)
- bat (optional, for formatted output)
EOF
}

# Check for required dependencies and install if missing
check_dependencies() {
    local missing=()
    for cmd in fzf bat; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        return
    fi

    echo "The following dependencies are missing: ${missing[*]}"
    read -p "Do you want to install them? (y/n): " install_confirm
    if [[ "$install_confirm" != "y" ]]; then
        echo "Dependencies are required to continue. Exiting."
        exit 1
    fi

    for cmd in "${missing[@]}"; do
        echo "Installing $cmd..."
        if [[ -f /etc/arch-release ]]; then
            sudo pacman -Sy --needed "$cmd"
        else
            echo "This script is designed for Arch Linux. Please install $cmd manually."
            exit 1
        fi
    done

    echo "Dependencies installed successfully."
}

# Display logical volumes with size
show_volumes() {
    lvs --noheadings -o lv_name,vg_name,lv_size --units g --separator '|' \
        | sed 's/^ *//;s/ *$//' \
        | column -t -s'|' \
        | bat --style=plain --paging=never --language=plaintext || cat
}

# Check if a volume is mounted
is_mounted() {
    local lv_path="$1"
    mount | grep -q "$lv_path"
}

# Interactive volume selection and resize operation
resize_volume() {
    local selected
    selected=$(lvs --noheadings -o lv_name,vg_name,lv_size --units g --separator '|' \
        | sed 's/^ *//;s/ *$//' \
        | fzf --prompt="Select LV to resize: " || true)

    if [[ -z "$selected" ]]; then
        echo "No selection made. Exiting."
        exit 1
    fi

    local lv_name vg_name lv_size lv_path
    lv_name=$(echo "$selected" | awk -F'|' '{print $1}')
    vg_name=$(echo "$selected" | awk -F'|' '{print $2}')
    lv_size=$(echo "$selected" | awk -F'|' '{print $3}')
    lv_path="/dev/$vg_name/$lv_name"

    echo "Selected LV: $lv_name in VG: $vg_name (Current size: $lv_size)"

    # Check if the volume is mounted
    if is_mounted "$lv_path"; then
        echo "Warning: Logical volume $lv_path is mounted. You must unmount it to resize."
        echo "For root volumes or critical filesystems, boot from an Arch Linux ISO and run this script."
        read -p "Do you want to continue anyway? (y/n): " confirm
        if [[ "$confirm" != "y" ]]; then
            echo "Operation canceled."
            exit 1
        fi
    fi

    # Prompt for shrinking or extending
    echo "Would you like to shrink or extend the selected volume?"
    echo "1) Shrink"
    echo "2) Extend"
    read -p "Enter your choice (1 or 2): " resize_choice

    case $resize_choice in
        1)
            echo "Shrinking $lv_path..."
            read -p "Enter the size to shrink by (e.g., -5G): " shrink_size
            echo "Shrinking $lv_path by $shrink_size..."
            sudo lvresize -r -L "$shrink_size" "$lv_path"
            echo "Shrinking completed."
            # Suggest extending another volume
            echo "You must extend another volume to use the freed space."
            echo "Displaying available volumes for extension:"
            resize_volume
            ;;
        2)
            echo "Extending $lv_path..."
            read -p "Enter the size to extend by (e.g., +5G): " extend_size
            echo "Extending $lv_path by $extend_size..."
            sudo lvresize -r -L "$extend_size" "$lv_path"
            echo "Extension completed."
            ;;
        *)
            echo "Invalid choice. Exiting."
            exit 1
            ;;
    esac
}

main() {
    check_dependencies

    if [[ $# -eq 0 ]]; then
        show_help
        echo
        read -p "Press ENTER to continue in interactive mode, or Ctrl+C to exit."
        resize_volume
    fi

    case "$1" in
        -h|--help)
            show_help
            ;;
        -r|--resize)
            resize_volume
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
