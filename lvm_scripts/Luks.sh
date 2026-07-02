# Devices from your lsblk
ROOT_LUKS_PART=/dev/nvme0n1p4
CRYPT_MAPPER=cryptroot
ROOT_LV=/dev/linux/root
SWAP_DEV=/dev/linux/swap          # leave empty if you do not use hibernation
SWAPFILE=                          # e.g., /swapfile (leave empty if unused)

# Safety backups
sudo cp -a /etc/mkinitcpio.conf{,.bak.$(date +%F)}
sudo cp -a /etc/default/grub{,.bak.$(date +%F)}

# UUID of the *LUKS partition* backing your crypt mapper
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_LUKS_PART"); echo "ROOT_UUID=$ROOT_UUID"

# If using a swapfile, compute resume_offset now (ignored otherwise)
if [[ -n "$SWAPFILE" ]]; then
  OFFSET=$(sudo filefrag -v "$SWAPFILE" | awk '/^ *0:/{print $4}' | sed 's/\.\.//')
  echo "resume_offset=$OFFSET"
fi
