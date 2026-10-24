# Arch Linux root on ZFS over LUKS2, alongside Windows

**Runbook date:** 2026-08-04  
**Target:** x86-64 Arch Linux, UEFI/GPT, one physical drive, Windows dual boot  
**Encryption:** LUKS2 below ZFS  
**Boot manager:** rEFInd  
**Arch kernel:** `linux-lts`, pinned to the version required by ArchZFS

This is a manual installation runbook, not a paste-all-at-once script. It has
deliberate inspection gates before every destructive operation. If the output
at a gate differs from the stated expectation, stop; do not improvise with a
different disk or partition name.

The runbook ends at a bootable, networked Arch console. Install a graphical
environment only after this storage and boot foundation has passed first-boot
validation.

The resulting storage stack is:

```text
UEFI firmware
  -> rEFInd and Arch kernel/initramfs on an unencrypted FAT32 ESP
  -> mkinitcpio encrypt hook
  -> LUKS2 partition opened as /dev/mapper/cryptzfs
  -> ZFS pool rpool
  -> rpool/ROOT/arch mounted as /
```

Windows remains on its existing partitions. Nothing in this guide formats,
moves, or mounts the Windows NTFS partition.

## 1. Important limitations

1. **This procedure can destroy Windows if the wrong partition is selected.**
   Make a tested backup and Windows recovery USB first.
2. **A single-disk ZFS pool has no data redundancy.** ZFS can detect checksum
   corruption but generally cannot repair damaged file data without a mirror,
   RAIDZ parity, or an additional copy. Snapshots are not backups.
3. **LUKS protects the ZFS labels and metadata as well as file data.** The EFI
   System Partition (ESP), kernel, initramfs, and rEFInd remain unencrypted so
   that UEFI can start the system.
4. **Encryption without Secure Boot does not prevent offline modification of
   the ESP.** This guide deliberately leaves Secure Boot disabled for the first
   successful boot. Secure Boot may be added afterward with controlled key
   enrollment and signed EFI binaries.
5. **OpenZFS is an out-of-tree Linux module.** Kernel and ZFS module versions
   must match. The guide therefore installs the exact `linux-lts` package
   required by `zfs-linux-lts`; it does not assume that the newest Arch kernel
   is usable.
6. The current ArchZFS repository is officially hosted as a GitHub release but
   is still labelled `experimental` by its maintainers. They explicitly advise
   caution on non-critical systems.

## 2. Intended partition layout

The Windows partition numbers shown below are examples only.

| GPT partition | Type | Purpose | Action in this guide |
|---|---|---|---|
| Existing ESP | FAT32 / EF00 | Windows boot files | Preserve |
| Existing MSR | Microsoft reserved | Windows | Preserve |
| Existing NTFS | NTFS | Windows | Preserve |
| Existing recovery | Microsoft recovery | Windows recovery | Preserve |
| `ARCH_EFI` | FAT32 / EF00 | Recommended dedicated Arch ESP, 1 GiB | Create |
| `ARCH_CRYPT` | Linux LUKS / 8309 | LUKS2 container for ZFS | Create |

A dedicated 1 GiB Arch ESP is recommended because many Windows ESPs are too
small for a Linux kernel and initramfs. If the existing Windows ESP is at least
512 MiB and has at least 250 MiB free, it may instead be shared. The shared-ESP
branch is explicitly marked below. Never format an existing Windows ESP.

## 3. Conventions

Commands before the `chroot` prompt are run as `root` in Alpine Extended.
Commands under the chroot section are run inside the new Arch installation.

These names are fixed throughout:

```text
GPT label for new Arch ESP:       ARCH_EFI
GPT label for encrypted root:     ARCH_CRYPT
LUKS mapper name:                 cryptzfs
ZFS pool:                         rpool
Root dataset:                     rpool/ROOT/arch
Mount point during installation:  /mnt
```

## 4. Prepare Windows before booting Linux

Perform this section from an elevated PowerShell or Command Prompt in Windows.

### 4.1 Back up and record recovery information

- Make an image or otherwise tested backup of irreplaceable data.
- Create Windows recovery/install media.
- If BitLocker is enabled, save its recovery key somewhere off the laptop.
- Record the current Windows partition layout with Disk Management or:

```powershell
Get-Disk
Get-Partition
Get-Volume
manage-bde.exe -status
```

### 4.2 Disable hibernation and Fast Startup

Fast Startup uses the Windows hibernation mechanism. Disable it before a
dual-boot installation:

```powershell
powercfg.exe /hibernate off
```

### 4.3 Suspend BitLocker if it is active

Suspending does not decrypt the volume; it temporarily exposes a clear key so
that planned boot and partition changes do not trigger recovery unexpectedly.

```powershell
Suspend-BitLocker -MountPoint 'C:' -RebootCount 0
```

If `Suspend-BitLocker` is unavailable, use:

```cmd
manage-bde.exe -protectors -disable C:
```

Do not resume BitLocker until both operating systems boot successfully.

### 4.4 Use UTC for the hardware clock

Arch keeps the hardware clock in UTC. Configure Windows to do the same so that
the two systems do not move the clock when alternating between them:

```powershell
reg.exe add `
  'HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' `
  /v RealTimeIsUniversal `
  /t REG_DWORD `
  /d 1 `
  /f
```

### 4.5 Shrink Windows from Windows

Use Windows Disk Management to shrink `C:` and leave the desired space as
**unallocated**. Do not create a filesystem in that space.

Allow at least:

- 1 GiB for a dedicated Arch ESP; and
- 40 GiB for a minimal usable Arch/ZFS root, preferably 80 GiB or more.

Then perform a full Windows shutdown:

```powershell
shutdown.exe /s /t 0
```

## 5. Prepare the installation medium

The ordinary Arch ISO does not ship the ZFS kernel module. The official
OpenZFS Arch root guide therefore recommends Alpine Extended, which includes
ZFS. At the runbook date, Alpine 3.24.1 is the newest stable point release.

From an existing Linux system:

```bash
ALPINE_VERSION='3.24.1'
ALPINE_ISO="alpine-extended-${ALPINE_VERSION}-x86_64.iso"
ALPINE_URL='https://dl-cdn.alpinelinux.org/alpine/latest-stable/'
ALPINE_URL="${ALPINE_URL}releases/x86_64"

curl --fail --location --remote-name \
  "${ALPINE_URL}/${ALPINE_ISO}"
curl --fail --location --remote-name \
  "${ALPINE_URL}/${ALPINE_ISO}.sha256"
curl --fail --location --remote-name \
  "${ALPINE_URL}/${ALPINE_ISO}.asc"

sha256sum --check "${ALPINE_ISO}.sha256"
gpg --auto-key-retrieve \
  --keyserver hkps://keyserver.ubuntu.com \
  --verify "${ALPINE_ISO}.asc" "${ALPINE_ISO}"
```

Identify the USB device carefully. The target below must be the entire USB
device, not a partition and not the laptop SSD:

```bash
lsblk --output NAME,PATH,SIZE,MODEL,TRAN,FSTYPE,MOUNTPOINTS
```

After replacing `/dev/sdX` with the verified USB device:

```bash
sudo umount /dev/sdX?* 2>/dev/null || true
sudo dd if="${ALPINE_ISO}" of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

## 6. Firmware and Alpine startup

1. Enter UEFI setup.
2. Confirm the machine is using UEFI mode, not CSM/legacy BIOS.
3. Disable Secure Boot temporarily.
4. Leave the storage controller in its existing mode. Do not change AHCI/RST
   casually; changing it can make Windows unbootable.
5. Boot the Alpine USB explicitly as a UEFI device.
6. Log in as `root`; the live image initially has no password.

Load the same Danish console keymap that the installed initramfs will use. This
is important for the LUKS passphrase, especially if it contains punctuation:

```sh
setup-keymap dk dk
```

Verify UEFI boot immediately:

```sh
test -d /sys/firmware/efi/efivars || {
  echo 'ERROR: Installation medium was not booted in UEFI mode.' >&2
  exit 1
}
```

Configure networking. For Ethernet, DHCP may already work. For the guided
network setup:

```sh
setup-interfaces -r
```

Typical Wi-Fi answers are the wireless interface, SSID, DHCP, then `done`.
Synchronize time and select an Alpine mirror:

```sh
setup-ntp busybox
setup-apkrepos
apk update
```

Install the live-environment tools:

```sh
apk add \
  cryptsetup \
  curl \
  dosfstools \
  e2fsprogs \
  eudev \
  gnupg \
  gptfdisk \
  parted \
  util-linux \
  zfs \
  zstd

setup-devd udev
modprobe zfs
zfs version
```

## 7. Inventory the disk: mandatory stop gate

List every disk, partition, filesystem, UUID, and mount point:

```sh
lsblk --bytes \
  --output NAME,PATH,SIZE,TYPE,FSTYPE,FSVER,LABEL,PARTLABEL,PARTUUID,MOUNTPOINTS
blkid
find /dev/disk/by-id -maxdepth 1 -type l -print
```

Choose the persistent whole-disk path. Example only:

```sh
DISK='/dev/disk/by-id/nvme-Samsung_SSD_EXAMPLE_SERIAL'
```

Verify that it resolves to the intended laptop disk:

```sh
readlink -f "${DISK}"
lsblk --output NAME,PATH,SIZE,MODEL,SERIAL,FSTYPE,PARTLABEL "${DISK}"
sgdisk --print "${DISK}"
```

**Stop unless all of the following are true:**

- `DISK` is the intended internal drive.
- The Windows EFI, MSR, NTFS, and recovery partitions are visible.
- The intended capacity appears as unallocated/free space.
- No existing partition occupies the space intended for Arch.

Do not run `wipefs`, `sgdisk --zap-all`, `mklabel`, `blkdiscard`, or any command
that recreates the disk partition table. Those commands would destroy the
dual-boot installation.

## 8. Create only the new Arch partitions

Start the interactive GPT editor:

```sh
cgdisk "${DISK}"
```

### Recommended branch: dedicated Arch ESP

Within the unallocated region only:

1. Select **Free space**.
2. Select **New**.
3. Accept the proposed first sector unless alignment is reported as invalid.
4. Enter `1G` as size (`cgdisk` uses `K`, `M`, `G`, `T`, and `P` suffixes).
5. Enter type code `EF00`.
6. Enter partition name `ARCH_EFI`.
7. Select the remaining free space and create another partition.
8. Use the remaining desired size.
9. Enter type code `8309` (Linux LUKS).
10. Enter partition name `ARCH_CRYPT`.
11. Select **Write**, type `yes`, and then **Quit**.

### Alternative branch: share an adequately sized Windows ESP

Create only the `ARCH_CRYPT` partition in free space using type `8309`. Do not
alter, rename, or format the Windows ESP. Later, set `ESP_PART` to that existing
ESP's `/dev/disk/by-partuuid/...` path.

Reload and inspect the table:

```sh
partprobe "${DISK}"
udevadm settle
lsblk --output NAME,PATH,SIZE,FSTYPE,PARTTYPE,PARTLABEL,PARTUUID "${DISK}"
sgdisk --print "${DISK}"
```

Set stable partition paths.

For the recommended dedicated-ESP branch:

```sh
ESP_PART='/dev/disk/by-partlabel/ARCH_EFI'
CRYPT_PART='/dev/disk/by-partlabel/ARCH_CRYPT'
```

For the shared-ESP branch, replace the first value with the existing Windows
ESP's exact PARTUUID path:

```sh
ESP_PART='/dev/disk/by-partuuid/REPLACE-WITH-WINDOWS-ESP-PARTUUID'
CRYPT_PART='/dev/disk/by-partlabel/ARCH_CRYPT'
```

Validate both variables:

```sh
for part in "${ESP_PART}" "${CRYPT_PART}"; do
  test -b "${part}" || {
    echo "ERROR: Not a block device: ${part}" >&2
    exit 1
  }
  readlink -f "${part}"
  lsblk --output NAME,PATH,SIZE,FSTYPE,PARTLABEL,PARTUUID "${part}"
done
```

The output for `CRYPT_PART` must say `ARCH_CRYPT` and must not contain NTFS or
Windows data. The ESP must be the new `ARCH_EFI` partition or the deliberately
selected existing FAT32 ESP.

## 9. Format or mount the ESP

Run **only one** branch.

For a newly created `ARCH_EFI` partition:

```sh
mkfs.fat -F 32 -n ARCH_EFI "${ESP_PART}"
```

For a shared Windows ESP, do not format it. Verify that it is FAT32:

```sh
blkid "${ESP_PART}"

mkdir -p /tmp/esp-check
mount -o ro "${ESP_PART}" /tmp/esp-check
df -h /tmp/esp-check
test -f /tmp/esp-check/EFI/Microsoft/Boot/bootmgfw.efi
umount /tmp/esp-check
rmdir /tmp/esp-check
```

Expected filesystem type: `TYPE="vfat"`. Confirm that the filesystem is at
least 512 MiB with at least 250 MiB available. If either condition fails, use a
dedicated Arch ESP instead.

## 10. Create the LUKS2 container

Inspect the target one last time:

```sh
lsblk --output NAME,PATH,SIZE,FSTYPE,PARTLABEL,PARTUUID "${CRYPT_PART}"
wipefs --no-act "${CRYPT_PART}"
```

The next command destroys all pre-existing data in `CRYPT_PART`. It must not be
an NTFS, recovery, or EFI partition.

```sh
cryptsetup luksFormat \
  --type luks2 \
  --pbkdf argon2id \
  --label cryptzfs \
  "${CRYPT_PART}"
```

Use a strong, unique passphrase. Open and inspect it:

```sh
cryptsetup open "${CRYPT_PART}" cryptzfs
cryptsetup status cryptzfs
cryptsetup luksDump "${CRYPT_PART}"
lsblk --output NAME,PATH,SIZE,TYPE,FSTYPE,LABEL "${CRYPT_PART}"
```

Expected stack:

```text
ARCH_CRYPT partition
└─cryptzfs  crypt
```

Do not enable discard/TRIM yet. Discard reveals allocation patterns through the
encryption layer. It can be enabled later after consciously accepting that
leakage.

## 11. Create the ZFS pool

Confirm that the compatibility profile exists:

```sh
test -f /usr/share/zfs/compatibility.d/openzfs-2.3-linux || {
  echo 'Available ZFS compatibility profiles:' >&2
  ls -1 /usr/share/zfs/compatibility.d >&2
  echo 'ERROR: Required compatibility profile is absent.' >&2
  exit 1
}
```

Create a single-vdev pool on the LUKS mapper:

```sh
zpool create -f \
  -o ashift=12 \
  -o autotrim=off \
  -o cachefile=none \
  -o compatibility=openzfs-2.3-linux \
  -R /mnt \
  -O acltype=posixacl \
  -O canmount=off \
  -O compression=lz4 \
  -O dnodesize=auto \
  -O normalization=formD \
  -O relatime=on \
  -O xattr=sa \
  -O mountpoint=none \
  rpool \
  /dev/mapper/cryptzfs
```

Why these properties matter:

- `ashift=12` aligns writes to 4 KiB sectors and cannot be reduced later.
- `compatibility=openzfs-2.3-linux` avoids accidentally enabling a new pool
  feature that the installed Arch ZFS module cannot import.
- `compression=lz4` is mature, low-overhead, and generally beneficial.
- `xattr=sa` and `acltype=posixacl` are suitable for Linux metadata and ACLs.
- `normalization=formD` prevents certain Unicode-equivalent duplicate names.
- `cachefile=none` makes early boot scan `/dev/mapper` explicitly rather than
  depending on a cache created by the temporary live environment.

Do not enable deduplication. It is not an ordinary space-saving switch and can
create severe memory and performance costs.

## 12. Create datasets and mount them

The root operating system is kept separate from home and volatile data so that
root snapshots do not also roll back personal data, logs, or package cache.
`/var/lib`, including the pacman database, deliberately remains in the root
dataset so package state and system files roll back together.

```sh
zfs create -o canmount=off -o mountpoint=none rpool/ROOT
zfs create \
  -o canmount=noauto \
  -o mountpoint=legacy \
  rpool/ROOT/arch

zfs create -o canmount=off -o mountpoint=none rpool/DATA
zfs create -o mountpoint=legacy rpool/DATA/home
zfs create -o mountpoint=legacy rpool/DATA/var-log
zfs create -o mountpoint=legacy rpool/DATA/var-cache
zfs create -o mountpoint=legacy rpool/DATA/var-tmp

zpool set bootfs=rpool/ROOT/arch rpool
```

Mount the datasets:

```sh
mkdir -p /mnt
mount -t zfs rpool/ROOT/arch /mnt

mkdir -p \
  /mnt/home \
  /mnt/var/log \
  /mnt/var/cache \
  /mnt/var/tmp \
  /mnt/boot

mount -t zfs rpool/DATA/home /mnt/home
mount -t zfs rpool/DATA/var-log /mnt/var/log
mount -t zfs rpool/DATA/var-cache /mnt/var/cache
mount -t zfs rpool/DATA/var-tmp /mnt/var/tmp
mount -t vfat -o umask=0077 "${ESP_PART}" /mnt/boot
chmod 1777 /mnt/var/tmp
```

Verify every mount:

```sh
findmnt --real
zpool status -v
zpool get ashift,autotrim,compatibility,bootfs rpool
zfs list -o name,used,avail,refer,mountpoint,canmount
```

## 13. Download and verify the Arch bootstrap tarball

The release pinned when this runbook was written is Arch 2026.08.01.

```sh
ARCH_RELEASE='2026.08.01'
ARCH_ARCHIVE="https://archive.archlinux.org/iso/${ARCH_RELEASE}"
ARCH_TARBALL="archlinux-bootstrap-${ARCH_RELEASE}-x86_64.tar.zst"

cd /tmp
curl --fail --location \
  "${ARCH_ARCHIVE}/${ARCH_TARBALL}" \
  --output "${ARCH_TARBALL}"
curl --fail --location \
  "${ARCH_ARCHIVE}/${ARCH_TARBALL}.sig" \
  --output "${ARCH_TARBALL}.sig"

gpg --auto-key-locate clear,wkd \
  --locate-external-key pierre@archlinux.org
gpg --verify "${ARCH_TARBALL}.sig" "${ARCH_TARBALL}"
```

Do not continue unless GnuPG reports a good signature from the Arch release
signing key. Extract the bootstrap root directly into the mounted root dataset:

```sh
ln -s /mnt /mnt/root.x86_64
zstd --decompress --stdout "${ARCH_TARBALL}" \
  | tar --extract --directory=/mnt root.x86_64
test -L /mnt/root.x86_64 && rm /mnt/root.x86_64
```

Confirm the target resembles an Arch root filesystem:

```sh
test -x /mnt/usr/bin/pacman
test -x /mnt/usr/bin/bash
ls -la /mnt
```

## 14. Prepare and enter the Arch chroot

```sh
cp -L /etc/resolv.conf /mnt/etc/resolv.conf

for path in dev proc sys run; do
  mount --rbind "/${path}" "/mnt/${path}"
  mount --make-rslave "/mnt/${path}"
done

chroot /mnt /usr/bin/env -i \
  ESP_PART="${ESP_PART}" \
  CRYPT_PART="${CRYPT_PART}" \
  HOME=/root \
  TERM="${TERM:-linux}" \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/bin \
  /bin/bash --login
```

The prompt is now inside the new Arch installation. Verify the two partition
variables survived the chroot boundary:

```bash
printf 'ESP_PART=%s\nCRYPT_PART=%s\n' "${ESP_PART}" "${CRYPT_PART}"
test -b "${ESP_PART}"
test -b "${CRYPT_PART}"
```

## 15. Initialize pacman and add the signed ArchZFS repository

Configure Arch's official geographic mirror, initialize the keyring, and fully
upgrade the bootstrap environment. The full `-Syu` is intentional: Arch does
not support partial upgrades.

```bash
tee /etc/pacman.d/mirrorlist >/dev/null <<'EOF'
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
EOF

pacman-key --init
pacman-key --populate archlinux
pacman -Syu --noconfirm archlinux-keyring
pacman-key --populate archlinux
```

Import the current ArchZFS signing key and locally certify the exact
fingerprint published by ArchZFS:

```bash
ARCHZFS_KEY='3A9917BF0DED5C13F69AC68FABEC0A1208037BE9'

pacman-key --recv-keys "${ARCHZFS_KEY}"
pacman-key --finger "${ARCHZFS_KEY}"
pacman-key --lsign-key "${ARCHZFS_KEY}"
```

The displayed fingerprint must exactly equal the value assigned above. Append
the repository using required package signatures:

```bash
tee -a /etc/pacman.conf >/dev/null <<'EOF'

[archzfs]
SigLevel = Required
Server = https://github.com/archzfs/archzfs/releases/download/experimental
EOF

pacman -Syy
```

Do not weaken this to `SigLevel = Never`.

## 16. Install the base system and a matching LTS kernel/ZFS pair

First install packages that do not require the kernel pair:

```bash
pacman -S --noconfirm --needed \
  base \
  base-devel \
  cryptsetup \
  efibootmgr \
  git \
  linux-firmware \
  man-db \
  man-pages \
  mkinitcpio \
  networkmanager \
  refind \
  sudo \
  texinfo \
  vim \
  wireless-regdb \
  zram-generator
```

Install the correct CPU microcode package:

```bash
if grep -q AuthenticAMD /proc/cpuinfo; then
  pacman -S --noconfirm --needed amd-ucode
elif grep -q GenuineIntel /proc/cpuinfo; then
  pacman -S --noconfirm --needed intel-ucode
else
  echo 'WARNING: CPU vendor not recognized; install microcode manually.' >&2
fi
```

Query the exact kernel version required by the current precompiled ZFS module:

```bash
ZFS_KERNEL_PACKAGE='zfs-linux-lts'
LINUX_LTS_VERSION="$(
  LC_ALL=C pacman -Si "${ZFS_KERNEL_PACKAGE}" \
    | sed -n \
      's/^Depends On[[:space:]]*:.*linux-lts=\([^ ]*\).*/\1/p'
)"

test -n "${LINUX_LTS_VERSION}" || {
  echo 'ERROR: Could not derive the required linux-lts version.' >&2
  pacman -Si "${ZFS_KERNEL_PACKAGE}" >&2
  exit 1
}

printf 'ArchZFS requires linux-lts %s\n' "${LINUX_LTS_VERSION}"
```

Install that exact kernel from the Arch Linux Archive, then the matching ZFS
module and utilities:

```bash
LINUX_LTS_URL='https://archive.archlinux.org/packages/l/linux-lts'
LINUX_LTS_URL="${LINUX_LTS_URL}/linux-lts-${LINUX_LTS_VERSION}"
LINUX_LTS_URL="${LINUX_LTS_URL}-x86_64.pkg.tar.zst"

pacman -U --noconfirm "${LINUX_LTS_URL}"
pacman -S --noconfirm --needed \
  "${ZFS_KERNEL_PACKAGE}" \
  zfs-utils
```

Verify package relationships and that a ZFS kernel module exists:

```bash
pacman -Q linux-lts zfs-linux-lts zfs-utils
pacman -Qi zfs-linux-lts | sed -n '/^Depends On/p'

KERNEL_RELEASE="$(
  find /usr/lib/modules \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -name '*-lts' \
    -printf '%f\n' \
    | sort -V \
    | tail -n 1
)"

test -n "${KERNEL_RELEASE}"
find "/usr/lib/modules/${KERNEL_RELEASE}" -name 'zfs.ko*' -print
```

At least one `zfs.ko` or compressed equivalent must be printed.

## 17. Configure timezone, locale, console, hostname, and users

The following uses Danish keyboard layout and Copenhagen time while retaining
an English Denmark locale:

```bash
ln -sf /usr/share/zoneinfo/Europe/Copenhagen /etc/localtime
hwclock --systohc

sed -i 's/^#en_DK.UTF-8 UTF-8/en_DK.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen

printf 'LANG=en_DK.UTF-8\n' > /etc/locale.conf
printf 'KEYMAP=dk\n' > /etc/vconsole.conf
printf 'archzfs\n' > /etc/hostname

tee /etc/hosts >/dev/null <<'EOF'
127.0.0.1 localhost
::1       localhost
127.0.1.1 archzfs.localdomain archzfs
EOF
```

Set the root password, create the normal user, and configure `sudo`:

```bash
passwd

useradd --create-home --groups wheel --shell /bin/bash heini
passwd heini

install -m 0440 /dev/null /etc/sudoers.d/10-wheel
printf '%%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/10-wheel
visudo --check --file=/etc/sudoers.d/10-wheel
```

Replace `archzfs` or `heini` before running the commands if different names are
desired.

## 18. Write and verify `/etc/fstab`

Obtain the actual FAT UUID and LUKS UUID:

```bash
ESP_UUID="$(blkid -s UUID -o value "${ESP_PART}")"
LUKS_UUID="$(blkid -s UUID -o value "${CRYPT_PART}")"

test -n "${ESP_UUID}"
test -n "${LUKS_UUID}"
printf 'ESP UUID:  %s\nLUKS UUID: %s\n' "${ESP_UUID}" "${LUKS_UUID}"
```

Create the mount table. The root entry is required because the `zfs`
mkinitcpio hook consults it when the root dataset uses `mountpoint=legacy`.

```bash
tee /etc/fstab >/dev/null <<EOF
# <source>                    <mount point> <type> <options>       <dump> <pass>
rpool/ROOT/arch               /             zfs    defaults       0      0
rpool/DATA/home               /home         zfs    defaults       0      0
rpool/DATA/var-log            /var/log      zfs    defaults       0      0
rpool/DATA/var-cache          /var/cache    zfs    defaults       0      0
rpool/DATA/var-tmp            /var/tmp      zfs    defaults       0      0
UUID=${ESP_UUID}              /boot         vfat   umask=0077     0      2
EOF

findmnt --verify --verbose --tab-file /etc/fstab
```

`findmnt` may note that the ZFS sources are not conventional block devices; it
must not report syntax errors, duplicate mount points, or an absent ESP UUID.

## 19. Configure ZFS identity, services, and zram

Create the stable host ID required for reliable pool import:

```bash
zgenhostid -f -o /etc/hostid
od -An -tx1 /etc/hostid
```

Enable the ZFS target/event daemon and ordinary system services:

```bash
systemctl enable \
  NetworkManager.service \
  systemd-timesyncd.service \
  zfs.target \
  zfs-zed.service
```

Use compressed RAM swap by default; this avoids the complications of a swap
ZVOL and deliberately provides no hibernation:

```bash
tee /etc/systemd/zram-generator.conf >/dev/null <<'EOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
swap-priority = 100
EOF
```

## 20. Build an initramfs that unlocks LUKS before importing ZFS

Use the busybox/udev hook family. Do not mix it with `systemd`/`sd-encrypt`; the
ArchZFS `zfs` hook used here is designed for the former sequence.

Create a mkinitcpio drop-in:

```bash
mkdir -p /etc/mkinitcpio.conf.d

tee /etc/mkinitcpio.conf.d/10-zfs-root.conf >/dev/null <<'EOF'
MODULES=(zfs)
BINARIES=()
FILES=(/etc/hostid)
HOOKS=(
  base
  udev
  autodetect
  microcode
  modconf
  kms
  keyboard
  keymap
  block
  encrypt
  zfs
  filesystems
)
EOF

mkinitcpio -P
```

The essential order is:

```text
block -> encrypt -> zfs -> filesystems
```

Inspect the generated image:

```bash
test -s /boot/initramfs-linux-lts.img
lsinitcpio /boot/initramfs-linux-lts.img \
  | grep -E '(^|/)(cryptsetup|hostid|zfs\.ko|zpool|mount\.zfs)'
```

The image must contain cryptsetup components, `/etc/hostid`, the ZFS module,
and ZFS userland required by the hook.

## 21. Install and configure rEFInd

With the ESP mounted at `/boot`, install rEFInd and create the UEFI NVRAM entry:

```bash
findmnt /boot
refind-install
```

The ArchZFS mkinitcpio hook currently understands both `root=ZFS=...` and
`zfs=...`. Use the explicit root dataset and scan only the mapper directory:

```bash
tee /boot/refind_linux.conf >/dev/null <<EOF
"Boot Arch Linux on encrypted ZFS"  "cryptdevice=UUID=${LUKS_UUID}:cryptzfs root=ZFS=rpool/ROOT/arch rw zfs_import_dir=/dev/mapper initrd=\\initramfs-linux-lts.img"
"Boot Arch Linux verbose"           "cryptdevice=UUID=${LUKS_UUID}:cryptzfs root=ZFS=rpool/ROOT/arch rw zfs_import_dir=/dev/mapper loglevel=7 initrd=\\initramfs-linux-lts.img"
EOF
```

Because the mkinitcpio `microcode` hook embeds early microcode into the
initramfs, no separate `amd-ucode.img` or `intel-ucode.img` argument is needed.

Optionally set a visible timeout:

```bash
REFIND_CONF='/boot/EFI/refind/refind.conf'
test -f "${REFIND_CONF}"
sed -i 's/^timeout .*/timeout 10/' "${REFIND_CONF}"
```

Verify the boot files and NVRAM entries:

```bash
ls -lh \
  /boot/vmlinuz-linux-lts \
  /boot/initramfs-linux-lts.img \
  /boot/refind_linux.conf \
  /boot/EFI/refind/refind_x64.efi

efibootmgr --verbose
```

The firmware list should retain `Windows Boot Manager` and add rEFInd. rEFInd
normally discovers `EFI/Microsoft/Boot/bootmgfw.efi` automatically, including
when it resides on another ESP. Even if it does not appear in rEFInd initially,
Windows remains bootable from the firmware's own boot menu.

Do not delete or overwrite the `EFI/Microsoft` directory.

## 22. Final pre-reboot validation

Run every check below inside the chroot:

```bash
set -o pipefail

pacman -Q linux-lts zfs-linux-lts zfs-utils cryptsetup refind
findmnt --verify --verbose --tab-file /etc/fstab
zpool status -v
zpool get ashift,autotrim,compatibility,bootfs rpool
zfs list -o name,mountpoint,canmount
test -s /etc/hostid
test -s /boot/vmlinuz-linux-lts
test -s /boot/initramfs-linux-lts.img
test -s /boot/EFI/refind/refind_x64.efi
test -s /boot/refind_linux.conf
grep -F "cryptdevice=UUID=${LUKS_UUID}:cryptzfs" \
  /boot/refind_linux.conf
grep -F 'root=ZFS=rpool/ROOT/arch' /boot/refind_linux.conf
systemctl --root=/ is-enabled NetworkManager.service
systemctl --root=/ is-enabled zfs.target
```

If any required check fails, do not reboot.

Create the first recursive snapshot while the installed state is known:

```bash
zfs snapshot -r rpool@fresh-install
zfs list -t snapshot
sync
exit
```

The prompt is now back in Alpine.

## 23. Cleanly unmount, export, and reboot

```sh
sync
umount -R /mnt
zpool export rpool
cryptsetup close cryptzfs

zpool list
ls /dev/mapper
```

`zpool list` should report no imported pools and `cryptzfs` should be absent.
Then reboot and remove the USB medium:

```sh
reboot
```

## 24. First boot

1. Select Arch Linux in rEFInd.
2. The initramfs should request the LUKS passphrase.
3. After successful decryption, the ZFS pool should import and Arch should
   reach the login prompt.
4. Log in as the normal user.

Verify the live system:

```bash
findmnt /
for target in /boot /home /var/log /var/cache /var/tmp; do
  findmnt "${target}"
done

lsblk --fs
zpool status -v
zpool get ashift,autotrim,compatibility,bootfs rpool
zfs list -o name,used,avail,refer,mountpoint,canmount
systemctl --failed
swapon --show
journalctl --boot --priority=warning
```

For Wi-Fi, create the connection with `sudo nmtui` if it was not configured
already; NetworkManager stores it for later boots.

Expected root source: `rpool/ROOT/arch`. Expected underlying ZFS device:
`/dev/mapper/cryptzfs`. Expected swap: `/dev/zram0` after the generator starts.

Boot Windows from rEFInd or the firmware menu. Once Windows and Arch have both
booted successfully, resume BitLocker from elevated PowerShell if applicable:

```powershell
Resume-BitLocker -MountPoint 'C:'
```

## 25. Back up the LUKS header and add a recovery passphrase

Do this after the first successful boot, with an external encrypted drive
mounted. Replace the output path with that external location:

```bash
sudo cryptsetup luksAddKey /dev/disk/by-partlabel/ARCH_CRYPT

sudo cryptsetup luksHeaderBackup \
  /dev/disk/by-partlabel/ARCH_CRYPT \
  --header-backup-file \
  /path/on/encrypted-external-drive/ARCH_CRYPT-luks2-header.img

sudo cryptsetup luksDump /dev/disk/by-partlabel/ARCH_CRYPT
```

The header backup does not itself contain the plaintext passphrase, but it is
security-sensitive: an old header preserves the key slots that existed when it
was copied and permits offline passphrase attacks. Store it encrypted and
offline. A passphrase cannot recover a destroyed LUKS header without a usable
header backup.

## 26. Optional SSD discard/TRIM

The privacy-conservative default is no discard through LUKS and
`autotrim=off`. If SSD space reclamation is more important than hiding block
allocation patterns:

1. Add `:allow-discards` to the `cryptdevice` option on both lines in
   `/boot/refind_linux.conf`:

   ```text
   cryptdevice=UUID=<UUID>:cryptzfs:allow-discards
   ```

2. Enable ZFS automatic TRIM:

   ```bash
   sudo zpool set autotrim=on rpool
   sudo zpool get autotrim rpool
   ```

For lower-end SSDs, leaving `autotrim=off` and periodically running
`sudo zpool trim rpool` may reduce continuous discard activity. Discards still
require the LUKS `allow-discards` option to reach the physical SSD.

## 27. Routine Arch/ZFS maintenance

### 27.1 Before every full upgrade

Create a root snapshot:

```bash
sudo zfs snapshot rpool/ROOT/arch@pre-upgrade-$(date +%F)
```

Refresh all packages together; partial upgrades are unsupported on Arch:

```bash
sudo pacman -Syu
```

If pacman reports a conflict between `linux-lts` and `zfs-linux-lts`, do not
force or ignore it. Wait for a matching ArchZFS build, or install the exact
compatible pair intentionally.

Before rebooting after an upgrade:

```bash
pacman -Q linux-lts zfs-linux-lts zfs-utils
find /usr/lib/modules -name 'zfs.ko*' -print
sudo mkinitcpio -P
test -s /boot/vmlinuz-linux-lts
test -s /boot/initramfs-linux-lts.img
```

Do not run `zpool upgrade -a` merely because `zpool status` reports available
features. Pool feature activation is one-way and can make recovery media with
older ZFS versions unable to import the pool. The compatibility profile is
intentional.

### 27.2 Scrub and inspect

For an ordinary laptop, a monthly scrub is reasonable:

```bash
sudo zpool scrub rpool
zpool status rpool
```

Inspect completion later with `zpool status`. Do not suspend or power off the
laptop unnecessarily during the first full scrub.

### 27.3 Keep real backups

At minimum, keep versioned backups of home and research data on another
physical device. Use ordinary incremental `zfs send` streams into an encrypted
destination where appropriate. Because this pool uses LUKS rather than native
ZFS encryption, its send stream is plaintext unless the transport or destination
encrypts it. A snapshot on `rpool` fails with the SSD and is not a backup.

## 28. Recovery from Alpine Extended

Boot the same Alpine Extended medium in UEFI mode, configure the network if
needed, and install the recovery tools:

```sh
setup-keymap dk dk
apk update
apk add cryptsetup eudev util-linux zfs
setup-devd udev
modprobe zfs
```

Open LUKS and inspect the pool before importing it:

```sh
cryptsetup open /dev/disk/by-partlabel/ARCH_CRYPT cryptzfs
zpool import -d /dev/mapper
```

Import without mounting, using an alternate root:

```sh
zpool import -N -R /mnt -d /dev/mapper rpool
```

If ZFS says the pool may be active on another system, first verify that the
installed OS is not running and that only this recovery environment has the
device open. Use `-f` only after that verification.

Mount the installation:

```sh
mount -t zfs rpool/ROOT/arch /mnt
mkdir -p \
  /mnt/home \
  /mnt/var/log \
  /mnt/var/cache \
  /mnt/var/tmp \
  /mnt/boot

mount -t zfs rpool/DATA/home /mnt/home
mount -t zfs rpool/DATA/var-log /mnt/var/log
mount -t zfs rpool/DATA/var-cache /mnt/var/cache
mount -t zfs rpool/DATA/var-tmp /mnt/var/tmp
mount -t vfat -o umask=0077 \
  /dev/disk/by-partlabel/ARCH_EFI \
  /mnt/boot
```

For a shared Windows ESP, substitute its exact PARTUUID path.

Bind the virtual filesystems and enter the system:

```sh
cp -L /etc/resolv.conf /mnt/etc/resolv.conf

for path in dev proc sys run; do
  mount --rbind "/${path}" "/mnt/${path}"
  mount --make-rslave "/mnt/${path}"
done

chroot /mnt /bin/bash --login
```

Common boot repair inside the chroot:

```bash
pacman -Q linux-lts zfs-linux-lts zfs-utils
mkinitcpio -P
refind-install
efibootmgr --verbose
```

Exit and close cleanly:

```bash
exit
```

```sh
sync
umount -R /mnt
zpool export rpool
cryptsetup close cryptzfs
reboot
```

## 29. Early-boot troubleshooting

### No LUKS passphrase prompt

From recovery, inspect `/boot/refind_linux.conf` and the initramfs:

```bash
grep cryptdevice /boot/refind_linux.conf
grep '^HOOKS' /etc/mkinitcpio.conf.d/10-zfs-root.conf
lsinitcpio /boot/initramfs-linux-lts.img | grep cryptsetup
```

Confirm that the LUKS UUID in rEFInd equals:

```bash
blkid -s UUID -o value /dev/disk/by-partlabel/ARCH_CRYPT
```

### LUKS unlocks, but ZFS pool is not found

At the initramfs emergency shell:

```sh
ls -l /dev/mapper
zpool import -d /dev/mapper
zpool import -N -d /dev/mapper rpool
zfs list
```

If the manual import works, check that the boot command line contains:

```text
root=ZFS=rpool/ROOT/arch rw zfs_import_dir=/dev/mapper
```

and that `encrypt` precedes `zfs` in `HOOKS`.

### ZFS module missing or invalid module format

This almost always indicates a kernel/ZFS mismatch. From recovery and chroot:

```bash
pacman -Q linux-lts zfs-linux-lts zfs-utils
pacman -Qi zfs-linux-lts | sed -n '/^Depends On/p'
find /usr/lib/modules -name 'zfs.ko*' -print
mkinitcpio -P
```

Install a compatible pair; do not force-load a module built for another kernel.

### rEFInd does not show Windows

First use the firmware boot menu and select `Windows Boot Manager`. Verify the
NVRAM entry:

```bash
efibootmgr --verbose
```

If the Microsoft entry and `EFI/Microsoft/Boot/bootmgfw.efi` still exist,
Windows has not been erased. Repair rEFInd scanning separately; do not reinstall
or format Windows partitions as a boot-menu troubleshooting step.

## 30. Primary references

- [OpenZFS: Arch Linux Root on ZFS](https://openzfs.github.io/openzfs-docs/Getting%20Started/Arch%20Linux/Root%20on%20ZFS.html)
- [ArchWiki: Install Arch Linux on ZFS](https://wiki.archlinux.org/title/Install_Arch_Linux_on_ZFS)
- [ArchWiki: ZFS](https://wiki.archlinux.org/title/ZFS)
- [ArchWiki: dm-crypt system configuration](https://wiki.archlinux.org/title/Dm-crypt/System_configuration)
- [ArchWiki: Dual boot with Windows](https://wiki.archlinux.org/title/Dual_boot_with_Windows)
- [ArchWiki: rEFInd](https://wiki.archlinux.org/title/REFInd)
- [ArchZFS current repository and signing instructions](https://github.com/archzfs/archzfs/releases/tag/experimental)
- [Current ArchZFS mkinitcpio ZFS hook](https://github.com/archzfs/archzfs/blob/master/src/zfs-utils/zfs-utils.initcpio.hook)
- [OpenZFS pool properties](https://openzfs.github.io/openzfs-docs/man/master/7/zpoolprops.7.html)
- [rEFInd: Methods of Booting Linux](https://www.rodsbooks.com/refind/linux.html)
- [Microsoft: disable and re-enable hibernation](https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/disable-and-re-enable-hibernation)
- [Microsoft: BitLocker operations guide](https://learn.microsoft.com/en-us/windows/security/operating-system-security/data-protection/bitlocker/operations-guide)
