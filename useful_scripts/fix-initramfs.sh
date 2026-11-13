#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Reversible migration for Heini's reported Arch Linux configuration.
# Builds images beside the originals; commits after every build succeeds.
# -----------------------------------------------------------------------------
set -Eeuo pipefail
export PATH=/usr/bin:/bin
export LC_ALL=C
umask 077

BASE=/var/lib/initramfs-warning-fix
UUID_EXPECTED=b1133fa3-2d44-4315-9702-d333c57516c2
CRYPT=/etc/crypttab
OLD=/etc/crypttab.initramfs
TWEAKS=/etc/sysctl.d/99-performance-tweaks.conf
NAMES=(linux-amd-drm-next linux-lts linux)
FILES=("$CRYPT" "$OLD" "$TWEAKS")
SNAPSHOT=''
STAGE=''
ARMED=0
LVM_SIZE=''
LVM_ORIGIN=''
LVM_VG=''

function help {
  cat <<'HELP'
Usage:
  sudo bash fix-initramfs-warnings.sh --dry-run
  sudo bash fix-initramfs-warnings.sh --apply [--lvm-snapshot 4G]
  sudo bash fix-initramfs-warnings.sh --rollback /var/lib/.../backup-...

Scope:
  Specifically for the three kernels and root UUID in the supplied log.
  Requires a separately mounted /boot and the original crypttab.initramfs.
  Refuses unexpected active crypttab entries in the deprecated file.
  Comments out only the three obsolete scheduler settings.
  Copies the active root entry to crypttab; preserves its existing options.
  Removes the deprecated file after saving it in a root-only backup directory.
  Rebuilds the three default images using /etc/mkinitcpio.conf, matching the log.
  Does not run presets, update GRUB, install packages or change kernel arguments.
  Custom mkinitcpio hooks still run, so review any locally added hooks first.

Optional LVM snapshot:
  --lvm-snapshot SIZE supports a conventional linear root LV, including ext4.
  SIZE (for example 4G) reserves unallocated space in the root volume group;
  free space INSIDE the filesystem is not enough. Never shrinks any volume.
  Creation failure stops the migration; it never silently skips the snapshot.
  Close applications first. This is a live, crash-consistent checkpoint, not an
  application-consistent backup. The script syncs but does not freeze root.
  Separate /boot, /home and /var volumes are not included in the root snapshot.
  The normal file/image backups are always made, with or without this option.
  Watch usage with: sudo lvs -o lv_name,origin,lv_size,data_percent,lv_attr
  A full classic snapshot becomes invalid. Remove it after a successful boot
  with: sudo lvremove VG/SNAPSHOT_NAME (use the exact printed name).
  Automatic file rollback leaves this optional snapshot in place.
  Whole-volume rollback is deliberately manual: lvconvert --merge VG/SNAPSHOT
  discards ALL later changes on the origin LV, not merely this script's edits.
  For root, arrange recovery from a live USB with origin and snapshot unmounted;
  coordinate /boot image recovery first. Do not merge just to undo this script.
  A snapshot is on the same disk and does not protect against disk failure.

Recovery:
  Backups contain the original three configuration files and three initramfs
  images, checksums, package inventory and a copy of this script. Rollback
  restores those files without rebuilding. It overwrites later edits to them.
  Package inventory and kernel checksums must still match to restore images.
  Do not run package updates concurrently or before deciding to keep the change.
  A repeat apply after migration is refused; use the saved rollback command.

  From an Arch installation USB, unlock and mount the installed system:
    cryptsetup open /dev/disk/by-uuid/b1133fa3-2d44-4315-9702-d333c57516c2 \
      cryptroot
    vgchange -ay linux
    mount /dev/mapper/linux-root /mnt
    cat /mnt/etc/fstab
  Your supplied /boot UUID is 183ea3b1-00f5-4936-aecc-d67449c562e1:
    mount /dev/disk/by-uuid/183ea3b1-00f5-4936-aecc-d67449c562e1 /mnt/boot
  Verify this still agrees with fstab. /efi is not modified by this script.
  Mount any separate /var filesystem too (the backups are under /var/lib).
  Do not guess partition numbers. Then:
    arch-chroot /mnt
    ls /var/lib/initramfs-warning-fix
    bash /var/lib/initramfs-warning-fix/backup-.../recovery.sh \
      --rollback /var/lib/initramfs-warning-fix/backup-...
  Substitute the printed backup directory. Reboot only after successful restore.

  If packages have changed, do not restore old initramfs images. Restore the
  appropriate configuration manually and run mkinitcpio -P inside the chroot.
  Installing amd-ucode alone does not fix an incorrect encryption configuration.

Limits:
  Restores the state immediately BEFORE this script, not before earlier manual
  edits or package upgrades. Existing images are not guaranteed to be bootable.
  Ordinary errors and INT/TERM trigger rollback once changes begin. Power loss,
  SIGKILL, disk failure and arbitrary custom-hook effects cannot be auto-undone.
  Retain the backup until a successful boot. Backups consume disk space.
HELP
}

function die {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

function regular {
  [[ -f "$1" && ! -L "$1" ]] || die "Not a regular, non-symlink file: $1"
}

function active_entries {
  awk 'NF && $1 !~ /^#/ {print}' "$1"
}

function atomic_copy {
  local source=$1 destination=$2 temporary
  temporary=$(mktemp "${destination}.restore.XXXXXX") || return 1
  if ! cp -a -- "$source" "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  if ! mv -fT -- "$temporary" "$destination"; then
    rm -f -- "$temporary"
    return 1
  fi
}

function restore_files {
  local path
  # Validate ALL backup bytes before restoring any of them.
  (cd "$SNAPSHOT" && sha256sum --status -c originals.sha256) || return 1
  for path in "${FILES[@]}"; do
    atomic_copy "$SNAPSHOT/originals$path" "$path" || return 1
  done
  sync || return 1
}

function finish {
  local status=$?
  trap - EXIT INT TERM
  if (( ARMED )); then
    printf '\nOperation interrupted or failed. Restoring saved files...\n' >&2
    if restore_files; then
      printf 'Original configuration and images restored.\n' >&2
    else
      printf 'RESTORE FAILED. Do not reboot. Backup: %s\n' "$SNAPSHOT" >&2
    fi
    status=1
  fi
  if [[ -n "$STAGE" ]]; then rm -rf -- "$STAGE"; fi
  exit "$status"
}

function main {
  local mode=${1:---dry-run} name path entry existing count options
  local total=0 bytes free_boot free_backup vg_free requested
  case "$mode" in
    -h|--help) help; return ;;
    --dry-run|--apply)
      if (( $# > 1 )); then
        [[ $# == 3 && $2 == --lvm-snapshot ]] || die 'Unexpected arguments.'
        [[ $3 =~ ^[1-9][0-9]{0,5}[MG]$ ]] || die 'Use a size such as 4G or 512M.'
        LVM_SIZE=$3
      fi
      ;;
    --rollback) (( $# == 2 )) || die 'Supply the backup directory.' ;;
    *) die 'Use --help for usage.' ;;
  esac
  (( EUID == 0 )) || die 'Run using sudo bash.'
  for name in awk cp cmp diff flock mkinitcpio mountpoint pacman sha256sum; do
    command -v "$name" >/dev/null || die "Missing command: $name"
  done
  mountpoint -q /boot || die '/boot must be separately mounted.'
  [[ ! -e /var/lib/pacman/db.lck ]] || die 'A package transaction is active.'
  # Lock this tool; this is not a lock against separately launched pacman.
  exec 9>/run/initramfs-warning-fix.lock
  flock -n 9 || die 'Another copy of this tool is running.'
  for name in "${NAMES[@]}"; do
    regular "/boot/vmlinuz-$name"
    regular "/boot/initramfs-$name.img"
    FILES+=("/boot/initramfs-$name.img")
  done

  if [[ "$mode" == --rollback ]]; then
    SNAPSHOT=$(realpath -e -- "$2")
    [[ "$SNAPSHOT" == "$BASE"/backup-* ]] || die 'Unexpected backup path.'
    [[ $(stat -c %u "$SNAPSHOT") == 0 ]] || die 'Backup must be root-owned.'
    [[ $(stat -c %a "$SNAPSHOT") == 700 ]] || die 'Backup must be mode 700.'
    regular "$SNAPSHOT/originals.sha256"
    cmp -s <(pacman -Q) "$SNAPSHOT/packages.txt" ||
      die 'Packages changed; restore configuration manually and rebuild.'
    sha256sum --status -c "$SNAPSHOT/kernels.sha256" ||
      die 'Kernel files changed; refusing to restore old initramfs images.'
    trap finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    restore_files || die "Restore incomplete. Keep backup: $SNAPSHOT"
    printf 'Restored configuration and images from: %s\n' "$SNAPSHOT"
    return
  fi

  for path in "$CRYPT" "$OLD" "$TWEAKS"; do regular "$path"; done
  entry=$(active_entries "$OLD")
  count=$(active_entries "$OLD" | awk 'END {print NR}')
  [[ "$count" == 1 ]] || die 'Expected one active crypttab.initramfs entry.'
  awk -v uuid="$UUID_EXPECTED" '
    NF && $1 !~ /^#/ {
      if ($1 != "cryptroot" || $2 != "UUID=" uuid || $3 != "none") exit 1
      if (NF != 4 || $4 !~ /(^|,)luks(,|$)/) exit 1
    }
  ' "$OLD" || die 'Root entry differs from the reviewed configuration.'
  existing=$(awk '$1 == "cryptroot" {print}' "$CRYPT")
  [[ -z "$existing" ]] || die 'crypttab already has an active cryptroot entry.'
  awk -v uuid="$UUID_EXPECTED" '
    $1 !~ /^#/ && $2 == "UUID=" uuid {found=1}
    END {exit found}
  ' "$CRYPT" || die 'Root UUID already has an active crypttab entry.'
  options=$(printf '%s\n' "$entry" | awk '{print $4}')
  case ",$options," in
    *,x-initrd.attach,*) ;;
    *) options+=,x-initrd.attach ;;
  esac
  entry="cryptroot UUID=$UUID_EXPECTED none $options"

  printf 'Planned crypttab entry:\n%s\n\n' "$entry"
  printf 'Disable these active obsolete settings, if present:\n'
  awk -v pat='^[[:space:]]*kernel[.]sched_' \
    -v names='(latency|min_granularity|wakeup_granularity)_ns[[:space:]]*=' \
    '$0 ~ (pat names) {print}' "$TWEAKS"
  printf '\nBack up and replace three default initramfs images.\n'
  printf 'Remove %s after backing it up.\n' "$OLD"
  if [[ -n "$LVM_SIZE" ]]; then
    for name in lvs vgs lvcreate findmnt; do
      command -v "$name" >/dev/null || die "Missing command: $name"
    done
    path=$(findmnt -nro SOURCE /)
    LVM_ORIGIN=$(lvs --noheadings -o lv_path "$path" | awk '{$1=$1; print}')
    [[ -n "$LVM_ORIGIN" ]] || die 'Root is not an identifiable LVM volume.'
    [[ $(lvs --noheadings -o segtype "$path" | awk '{$1=$1; print}' |
      sort -u) == linear ]] || die 'Snapshot option requires linear root LVM.'
    LVM_VG=$(lvs --noheadings -o vg_name "$path" | awk '{$1=$1; print}')
    printf '\nOptional snapshot: origin=%s, reserve=%s\n' \
      "$LVM_ORIGIN" "$LVM_SIZE"
    vgs -o vg_name,vg_free "$LVM_VG"
    vg_free=$(vgs --noheadings --units b --nosuffix -o vg_free "$LVM_VG" |
      awk '{printf "%.0f", $1}')
    requested=${LVM_SIZE%?}
    case "$LVM_SIZE" in
      *G) requested=$((10#$requested * 1024 * 1024 * 1024)) ;;
      *M) requested=$((10#$requested * 1024 * 1024)) ;;
    esac
    (( vg_free >= requested )) ||
      die 'Not enough unallocated VG space. Omit --lvm-snapshot; no resizing.' 
  fi
  [[ "$mode" == --apply ]] || return 0

  for path in "${FILES[@]}"; do
    bytes=$(stat -c %s "$path")
    total=$((total + bytes))
  done
  install -d -m 700 "$BASE"
  free_boot=$(df -B1 --output=avail /boot | awk 'NR == 2 {print $1}')
  free_backup=$(df -B1 --output=avail "$BASE" | awk 'NR == 2 {print $1}')
  # Conservative headroom for larger generated images and atomic restoration.
  (( free_boot > total * 2 + 134217728 )) || die 'Insufficient /boot space.'
  (( free_backup > total + 67108864 )) || die 'Insufficient backup space.'
  SNAPSHOT=$(mktemp -d "$BASE/backup-$(date +%Y%m%d-%H%M%S)-XXXXXX")
  mkdir "$SNAPSHOT/originals"
  for path in "${FILES[@]}"; do
    cp -a --parents -- "$path" "$SNAPSHOT/originals/"
  done
  (cd "$SNAPSHOT"; for path in "${FILES[@]}"; do
    sha256sum "originals$path"
  done) > "$SNAPSHOT/originals.sha256"
  pacman -Q > "$SNAPSHOT/packages.txt"
  for name in "${NAMES[@]}"; do sha256sum "/boot/vmlinuz-$name"; done \
    > "$SNAPSHOT/kernels.sha256"
  cp -- "${BASH_SOURCE[0]}" "$SNAPSHOT/recovery.sh"
  (cd "$SNAPSHOT" && sha256sum --status -c originals.sha256)
  sync
  printf '\nBackup: %s\nRollback command:\n' "$SNAPSHOT"
  printf 'sudo bash %q --rollback %q\n\n' \
    "$SNAPSHOT/recovery.sh" "$SNAPSHOT"

  trap finish EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  STAGE=$(mktemp -d /boot/.initramfs-warning-fix.XXXXXX)
  cp -a "$CRYPT" "$SNAPSHOT/crypttab.new"
  printf '\n# Early boot encrypted root (mkinitcpio sd-encrypt).\n%s\n' \
    "$entry" >> "$SNAPSHOT/crypttab.new"
  cp -a "$TWEAKS" "$SNAPSHOT/tweaks.new"
  awk -v pat='^[[:space:]]*kernel[.]sched_' \
    -v names='(latency|min_granularity|wakeup_granularity)_ns[[:space:]]*=' '
    $0 ~ (pat names) {
      print "# Disabled obsolete sysctl: " $0; next
    }
    {print}
  ' "$TWEAKS" > "$SNAPSHOT/tweaks.new"

  if [[ -n "$LVM_SIZE" ]]; then
    name="initramfs_fix_$(date +%Y%m%d_%H%M%S)_$$"
    printf '%s/%s\n' "$LVM_VG" "$name" > "$SNAPSHOT/lvm-snapshot.txt"
    sync
    lvcreate --snapshot --size "$LVM_SIZE" --name "$name" "$LVM_ORIGIN"
    printf 'LVM snapshot created: %s/%s\n' "$LVM_VG" "$name"
    printf 'It remains until explicitly removed; monitor its Data%% usage.\n'
  fi
  ARMED=1
  atomic_copy "$SNAPSHOT/crypttab.new" "$CRYPT"
  atomic_copy "$SNAPSHOT/tweaks.new" "$TWEAKS"
  rm -- "$OLD"
  for name in "${NAMES[@]}"; do
    mkinitcpio -c /etc/mkinitcpio.conf -k "/boot/vmlinuz-$name" \
      -g "$STAGE/initramfs-$name.img" 2>&1 | tee "$SNAPSHOT/$name.log"
    [[ -s "$STAGE/initramfs-$name.img" ]] || die "Empty image: $name"
    chown --reference="/boot/initramfs-$name.img" \
      "$STAGE/initramfs-$name.img"
    chmod --reference="/boot/initramfs-$name.img" \
      "$STAGE/initramfs-$name.img"
  done
  # Refuse a package/kernel change that happened while building.
  cmp -s <(pacman -Q) "$SNAPSHOT/packages.txt" || die 'Packages changed.'
  sha256sum --status -c "$SNAPSHOT/kernels.sha256"
  for name in "${NAMES[@]}"; do
    mv -fT "$STAGE/initramfs-$name.img" "/boot/initramfs-$name.img"
  done
  sync
  ARMED=0
  printf '\nSUCCESS. Keep the backup until a successful boot: %s\n' "$SNAPSHOT"
  printf 'Rollback restores the original image bytes; no rebuild is needed.\n'
}

main "$@"

