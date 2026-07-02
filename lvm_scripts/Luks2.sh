# Overwrite HOOKS with a clean, GPU-friendly udev stack.
# Keep lvm2 because your root sits on LVM. Add 'resume' only if using swap.
if [[ -n "$SWAP_DEV" || -n "$SWAPFILE" ]]; then
  NEW_HOOKS='HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt lvm2 resume filesystems fsck)'
else
  NEW_HOOKS='HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt lvm2 filesystems fsck)'
fi

# Replace HOOKS line and strip any sd-* hooks or duplicate resume.
sudo sed -i -E 's/^HOOKS=\(.*\)$//' /etc/mkinitcpio.conf
echo "$NEW_HOOKS" | sudo tee -a /etc/mkinitcpio.conf >/dev/null
sudo sed -i -E 's/\bsd-(encrypt|resume|shutdown|vconsole)\b//g' /etc/mkinitcpio.conf
sudo sed -i -E 's/(^HOOKS=\(| )resume( |))/\1/g' /etc/mkinitcpio.conf  # de-dupe safety
