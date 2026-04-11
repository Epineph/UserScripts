LUKS_MAPPER_NAME="$(
  sudo pvs --noheadings -o pv_name | awk -F/ '{print $NF}'
)"

ENCRYPTED_PARTITION="$(
  sudo cryptsetup status "$LUKS_MAPPER_NAME" |
    awk '/^[[:space:]]*device:/ { print $2 }'
)"

ENCRYPTED_PARTITION_UUID="$(
  sudo blkid -o value -s UUID "$ENCRYPTED_PARTITION"
)"

printf '%s UUID=%s none luks,discard\n' \
  "$LUKS_MAPPER_NAME" \
  "$ENCRYPTED_PARTITION_UUID" | sudo tee -a /etc/crypttab
