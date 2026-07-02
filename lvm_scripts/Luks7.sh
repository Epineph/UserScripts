sudo mkinitcpio -P
sudo grub-mkconfig -o /boot/grub/grub.cfg

# Sanity: the initramfs must contain 'encrypt' (and 'resume' if enabled)
lsinitcpio /boot/initramfs-linux.img | grep -E '(^|/)encrypt($|/)' >/dev/null && echo "encrypt present"
if [[ -n "$SWAP_DEV" || -n "$SWAPFILE" ]]; then
  lsinitcpio /boot/initramfs-linux.img | grep -q '/resume$' && echo "resume present (or built-in)"
fi
