#!/usr/bin/env bash
#
# backup_keys.sh
#
# This script creates a tar archive of selected sensitive files (GPG keys and SSH keys),
# then encrypts the archive using GPG (symmetric encryption). It supports multiple
# target paths: local directories, mounted external drives, or remote servers via SSH.
#

############################
#      CONFIGURATION       #
############################

FILES_TO_BACKUP=(
  "$HOME/.gnupg/private-keys-v1.d/"  # Modern private key storage
  "$HOME/.gnupg/pubring.kbx"         # Modern public key storage
  "$HOME/.ssh/id_rsa"                # SSH private key
  "$HOME/.ssh/id_rsa.pub"            # SSH public key
)


TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TMP_TAR_FILE="/tmp/backup_keys_${TIMESTAMP}.tar.gz"
ENCRYPTED_FILE="backup_keys_${TIMESTAMP}.tar.gz.gpg"

############################
#      HELP FUNCTION       #
############################

function show_help() {
  if command -v bat &>/dev/null; then
    bat --style="grid,header" \
        --theme="Dracula" \
        --color="always" \
        --paging="never" \
        --chop-long-lines \
        --language="less" <<'EOF'
USAGE:
    backup_keys.sh [OPTIONS]

DESCRIPTION:
    This script creates a tar archive of selected sensitive files (GPG keys and SSH keys),
    then encrypts the archive using GPG (symmetric encryption). It supports multiple
    target paths: local directories, mounted external drives, or remote servers via SSH.

OPTIONS:
    -t | --target <target1> [<target2> ...]
        Specify one or more target paths to copy the encrypted tarball. These can be local
        paths (like /mnt/external_drive) or in the format user@remote:/path for remote SSH/scp transfer.

    -h | --help
        Display this help text.

EXAMPLE:
    ./backup_keys.sh -t /backup_dir /mnt/external_drive user@192.168.1.10:/home/user
EOF
  else
    cat <<'EOF'
USAGE:
    backup_keys.sh [OPTIONS]

DESCRIPTION:
    This script creates a tar archive of selected sensitive files (GPG keys and SSH keys),
    then encrypts the archive using GPG (symmetric encryption). It supports multiple
    target paths: local directories, mounted external drives, or remote servers via SSH.

OPTIONS:
    -t | --target <target1> [<target2> ...]
        Specify one or more target paths to copy the encrypted tarball. These can be local
        paths (like /mnt/external_drive) or in the format user@remote:/path for remote SSH/scp transfer.

    -h | --help
        Display this help text.

EXAMPLE:
    ./backup_keys.sh -t /backup_dir /mnt/external_drive user@192.168.1.10:/home/user
EOF
  fi
}

############################
#      ERROR HANDLING      #
############################

function die() {
  echo "ERROR: $1"
  exit 1
}

############################
#   PARSE SCRIPT OPTIONS   #
############################

TARGET_PATHS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target)
      shift
      while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
        TARGET_PATHS+=("$1")
        shift
      done
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      show_help
      exit 1
      ;;
  esac
done

if [[ ${#TARGET_PATHS[@]} -eq 0 ]]; then
  echo "No target paths specified. Use -t or --target to set at least one."
  show_help
  exit 1
fi

############################
#   COLLECT PASSPHRASE     #
############################

echo "Please enter the passphrase to encrypt the tarball:"
read -s PASSPHRASE
if [[ -z "$PASSPHRASE" ]]; then
  die "No passphrase entered, aborting."
fi

echo "Re-enter passphrase for confirmation:"
read -s PASSPHRASE_CONFIRM
if [[ "$PASSPHRASE" != "$PASSPHRASE_CONFIRM" ]]; then
  die "Passphrases did not match. Aborting."
fi
echo "Passphrase confirmed."

############################
#     CREATE THE TARBALL   #
############################

echo "Verifying existence of files:"
EXISTING_FILES=()
for FILE in "${FILES_TO_BACKUP[@]}"; do
  if [[ -f "$FILE" ]]; then
    echo "Found $FILE."
    EXISTING_FILES+=("$FILE")
  else
    echo "WARNING: $FILE does not exist. Skipping..."
  fi
done

if [[ ${#EXISTING_FILES[@]} -eq 0 ]]; then
  die "No valid files found to backup. Aborting."
fi

echo "Creating compressed tar archive at $TMP_TAR_FILE..."
tar -czf "$TMP_TAR_FILE" --absolute-names "${EXISTING_FILES[@]}" || die "Failed to create the tar archive."
echo "Archive created: $TMP_TAR_FILE"

############################
#    ENCRYPT THE TARBALL   #
############################

echo "Encrypting archive using GPG (symmetric encryption)..."
echo "$PASSPHRASE" | gpg --batch --yes --passphrase-fd 0 --symmetric --cipher-algo AES256 \
  --output "$ENCRYPTED_FILE" "$TMP_TAR_FILE" || die "Encryption failed."
echo "Encrypted tarball created: $ENCRYPTED_FILE"

rm -f "$TMP_TAR_FILE"

############################
#      TRANSFER/STORE      #
############################

echo "Copying encrypted tarball to target path(s)..."
for TARGET in "${TARGET_PATHS[@]}"; do
  echo "Processing target: $TARGET"
  if [[ "$TARGET" =~ "@" ]]; then
    scp "$ENCRYPTED_FILE" "$TARGET" || echo "Failed to copy to remote path: $TARGET"
  else
    cp "$ENCRYPTED_FILE" "$TARGET" || echo "Failed to copy to local path: $TARGET"
  fi
done

echo "Operation complete. Encrypted tarball remains locally as: $ENCRYPTED_FILE"

exit 0

