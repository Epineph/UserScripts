#!/usr/bin/env bash
# automated_tools_iso_script.sh
#
# Build a custom Arch ISO with extra CLI tools preinstalled in the live system:
#   - fzf
#   - lsof
#   - strace
#   - git
#   - gptfdisk
#
# Heavily simplified from your old ZFS ISO script:
#   - No ZFS AUR packages
#   - No custom repos
#   - No HTML scraping / date pinning
#
# Host requirements:
#   - archiso (for mkarchiso)
#   - ddrescue (optional, for burning ISO)
#
# Result:
#   - ISO is created under:  \$HOME/ISOBUILD/toolsiso/ISOOUT/
#   - You can optionally burn it to a USB device using ddrescue.

set -euo pipefail
IFS=$'\n\t'

# ────────────────────────── Global paths ──────────────────────────────

USER_DIR="/home/$USER"
ISO_HOME="$USER_DIR/ISOBUILD/toolsiso"
ISO_LOCATION="$ISO_HOME/ISOOUT"
ISO_GLOB="$ISO_LOCATION/archlinux-*.iso"

# ─────────────────────── Helper functions ─────────────────────────────

function usage() {
	cat <<EOF
automated_tools_iso_script.sh — build a custom Arch ISO with dev tools.

Usage:
  ./automated_tools_iso_script.sh

This will:
  1) Ensure required host packages are installed:
       - archiso
       - ddrescue (for optional USB burning)
  2) Copy the official 'releng' profile to:
       $ISO_HOME
  3) Append these packages to packages.x86_64 for the LIVE ISO:
       - fzf
       - lsof
       - strace
       - git
       - gptfdisk
  4) Enable ParallelDownloads and multilib in pacman.conf (ISO).
  5) Run mkarchiso to produce a custom ISO in:
       $ISO_LOCATION

After build, you'll be asked whether to burn the ISO to a USB device
using ddrescue.

Run this from a normal Arch host with network access.
EOF
}

function check_and_install_packages() {
	local missing=()
	local pkg

	for pkg in "$@"; do
		if ! pacman -Qi "$pkg" &>/dev/null; then
			missing+=("$pkg")
		else
			echo "Host package '$pkg' already installed."
		fi
	done

	if ((${#missing[@]} > 0)); then
		echo
		echo "The following host packages are missing: ${missing[*]}"
		read -r -p "Install them now with pacman? (Y/n) " and
		and="${and:-Y}"
		if [[ "$and" =~ ^[Yy]$ ]]; then
			sudo pacman -S --needed "${missing[@]}"
		else
			echo "Required host packages not installed; aborting."
			exit 1
		fi
	fi
}

function save_iso_file() {
	local target_dir="$USER_DIR/custom_iso"
	mkdir -p "$target_dir"

	local iso_file
	iso_file="$(ls "$ISO_GLOB" 2>/dev/null | head -n1 || true)"

	if [[ -n "$iso_file" && -f "$iso_file" ]]; then
		cp "$iso_file" "$target_dir/"
		echo "ISO file saved to: $target_dir"
	else
		echo "No ISO file found in $ISO_LOCATION"
	fi
}

function list_devices() {
	echo "Available block devices:"
	lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
}

function burn_iso_to_usb() {
	local iso="$1"
	local device="$2"

	if ! command -v ddrescue >/dev/null 2>&1; then
		echo "ddrescue not found; installing on host..."
		sudo pacman -S --needed ddrescue
	fi

	echo
	echo "About to burn:"
	echo "  ISO:    $iso"
	echo "  Device: $device"
	echo
	read -r -p "THIS WILL DESTROY ALL DATA ON $device. Type 'YES' to continue: " and
	if [[ "$and" != "YES" ]]; then
		echo "Aborting USB burn."
		return 1
	fi

	sudo ddrescue -d -D --force "$iso" "$device"
	echo "ddrescue completed."
}

function locate_and_burn_iso() {
	local iso_file
	iso_file="$(ls "$ISO_GLOB" 2>/dev/null | head -n1 || true)"

	if [[ -z "$iso_file" ]]; then
		echo "No ISO file found in $ISO_LOCATION"
		return 1
	fi

	echo
	echo "Found ISO: $iso_file"
	list_devices
	echo
	read -r -p "Enter target device (e.g. /dev/sda, /dev/nvme0n1): " device

	if [[ -b "$device" ]]; then
		burn_iso_to_usb "$iso_file" "$device"
	else
		echo "Invalid block device: $device"
		return 1
	fi
}

# ───────────────────────────── Main ──────────────────────────────────

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
	usage
	exit 0
fi

# 1) Ensure host has required packages
check_and_install_packages archiso

# 2) Prepare ISO build directory
echo
echo "Preparing ISO build directory at: $ISO_HOME"
mkdir -p "$USER_DIR/ISOBUILD"
rm -rf "$ISO_HOME"
cp -r /usr/share/archiso/configs/releng "$ISO_HOME"

# 3) Adjust pacman.conf for the ISO (ParallelDownloads + multilib)
PACMAN_CONF="$ISO_HOME/pacman.conf"

echo "Enabling ParallelDownloads in ISO pacman.conf..."
sed -i '/^#ParallelDownloads/s/^#//' "$PACMAN_CONF"

echo "Uncommenting [multilib] in ISO pacman.conf..."
sed -i '/^\[multilib\]/,/^Include/ s/^#//' "$PACMAN_CONF"

# 4) Append custom tools to packages.x86_64 for the live ISO
CUSTOM_PKGS=(fzf lsof strace git gptfdisk)

echo
echo "Appending custom packages to $ISO_HOME/packages.x86_64:"
printf '  %s\n' "${CUSTOM_PKGS[@]}"

{
	echo
	echo "# Custom CLI / debug tools"
	for pkg in "${CUSTOM_PKGS[@]}"; do
		echo "$pkg"
	done
} | sudo tee -a "$ISO_HOME/packages.x86_64" >/dev/null

# 5) Build ISO
mkdir -p "$ISO_HOME/WORK" "$ISO_HOME/ISOOUT"

echo
echo "Running mkarchiso..."
(
	cd "$ISO_HOME"
	sudo mkarchiso -v -w WORK -o ISOOUT .
)

echo
echo "ISO build complete. Contents of $ISO_LOCATION:"
ls -lh "$ISO_LOCATION" || true

# 6) Offer to save ISO somewhere simple
echo
read -r -p "Copy ISO to $USER_DIR/custom_iso for convenience? (Y/n) " save_ans
save_ans="${save_ans:-Y}"
if [[ "$save_ans" =~ ^[Yy]$ ]]; then
	save_iso_file
fi

# 7) Offer to burn ISO to USB
echo
read -r -p "Burn ISO to USB now with ddrescue? (yes/no) " burn_ans
if [[ "$burn_ans" == "yes" ]]; then
	locate_and_burn_iso
else
	echo "Skipping USB burn."
fi

echo
echo "Done. ISO build directory: $ISO_HOME"
echo "ISO files in:              $ISO_LOCATION"
