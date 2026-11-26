#!/usr/bin/env bash
# Repair the regular Arch kernel from a working linux-lts boot.
set -euo pipefail

function fail() {
  printf 'repair-linux.sh: %s\n' "$*" >&2
  exit 1
}

function usage() {
  cat <<'EOF'
Usage: repair-linux.sh [--check | --apply]

  --check   Check the running kernel, mounts and source image (default).
  --apply   Run the checks, then rebuild the regular kernel files in /boot.

After booting linux-lts:
  ~/repair-linux.sh
  ~/repair-linux.sh --apply
EOF
}

(($# <= 1)) || fail 'Expected one option at most. See --help.'
mode=${1:---check}
case "$mode" in
  -h | --help)
    usage
    exit 0
    ;;
  --check | --apply) ;;
  *) fail "Unknown option '$mode'. See --help." ;;
esac

# --- Check the boot that will serve as the fallback ---------------------------
running=$(uname -r)
pkgbase="/usr/lib/modules/$running/pkgbase"
if [[ ! -r "$pkgbase" ]] || [[ $(<"$pkgbase") != linux-lts ]]; then
  fail "Running $running. Boot the linux-lts GRUB entry first."
fi
findmnt -rn -M /efi -S /dev/nvme0n1p1 -t vfat -o TARGET,SOURCE,FSTYPE ||
  fail 'Expected /dev/nvme0n1p1 mounted as vfat at /efi.'
findmnt -rn -M /boot -S /dev/nvme0n1p6 -t ext4 -O rw -o TARGET,SOURCE,OPTIONS ||
  fail 'Expected /dev/nvme0n1p6 mounted read-write as ext4 at /boot.'

# Select the installed regular kernel even though uname reports linux-lts.
linux_image=$(pacman -Qlq linux | awk '/^\/usr\/lib\/modules\/[^/]+\/vmlinuz$/')
[[ -f "$linux_image" && -r "$linux_image" ]] ||
  fail 'Could not identify one readable kernel image owned by the linux package.'
module_dir=${linux_image%/*}
release=${module_dir##*/}
printf 'Running %s. Regular kernel source is %s.\n' "$running" "$linux_image"
if [[ "$mode" == --check ]]; then
  printf 'Checks passed. Run with --apply to repair linux.\n'
  exit 0
fi

# --- Build and verify both files before replacing either boot file ------------
stage=$(sudo mktemp -d -- /boot/.repair-linux.XXXXXXXX)
function cleanup() {
  sudo rm -f -- "$stage/vmlinuz-linux" "$stage/initramfs-linux.img" \
    "$stage/previous-kernel"
  sudo rmdir -- "$stage"
}
trap cleanup EXIT

sudo install -m 0644 -- "$linux_image" "$stage/vmlinuz-linux"
# This host's linux preset uses the default mkinitcpio config and a plain image.
sudo mkinitcpio -k "$linux_image" -g "$stage/initramfs-linux.img"
sudo cmp -- "$linux_image" "$stage/vmlinuz-linux"
sudo lsinitcpio --nocolor --analyze "$stage/initramfs-linux.img" |
  awk -v want="$release" '$2 == "Kernel:" { print; ok = ($3 == want) }
                          END { exit !ok }' ||
  fail "Could not verify the initramfs kernel release as $release."

# Rename on the same filesystem. Keep the old kernel until both renames succeed.
boot_kernel=/boot/vmlinuz-linux
if [[ -e "$boot_kernel" ]]; then
  sudo ln -- "$boot_kernel" "$stage/previous-kernel"
fi
sudo mv -fT -- "$stage/vmlinuz-linux" "$boot_kernel"
if ! sudo mv -fT -- "$stage/initramfs-linux.img" /boot/initramfs-linux.img; then
  if sudo test -e "$stage/previous-kernel"; then
    sudo mv -fT -- "$stage/previous-kernel" "$boot_kernel" ||
      {
        trap - EXIT
        fail "Recovery files are in $stage. Stay on linux-lts."
      }
  else
    sudo rm -f -- "$boot_kernel"
  fi
  fail 'Installing the initramfs failed. Stay on linux-lts.'
fi
printf 'Installed regular linux %s. Select linux in GRUB for a test boot.\n' \
  "$release"
