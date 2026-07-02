if [[ -n "$SWAP_DEV" ]]; then
  NEW_CMDLINE="cryptdevice=UUID=$ROOT_UUID:$CRYPT_MAPPER root=$ROOT_LV resume=$SWAP_DEV"
elif [[ -n "$SWAPFILE" ]]; then
  NEW_CMDLINE="cryptdevice=UUID=$ROOT_UUID:$CRYPT_MAPPER root=$ROOT_LV resume=$ROOT_LV resume_offset=$OFFSET"
else
  NEW_CMDLINE="cryptdevice=UUID=$ROOT_UUID:$CRYPT_MAPPER root=$ROOT_LV"
fi

sudo sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$NEW_CMDLINE\"|" /etc/default/grub
grep ^GRUB_CMDLINE_LINUX /etc/default/grub
