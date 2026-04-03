old ZFS scripts are for root-on-ZFS across multiple disks (and even RAID-0 /boot)—they don’t match your current layout and will collide with mdraid/LUKS. For this project you only want a stand-alone ZFS data pool on the spare ~200 GiB NVMe partition. Below is a clean, minimal, and safe procedure.

I will automatically pick the correct free partition: if /dev/nvme1n1p5 exists I’ll use it; otherwise I’ll use /dev/nvme0n1p5 (which your last lsblk shows present and unused).

Step-by-step (concise, copy-paste)

# 0) Choose target partition (prefer nvme1n1p5; else nvme0n1p5)
DEV=/dev/nvme1n1p5; [ -b "$DEV" ] || DEV=/dev/nvme0n1p5
echo "Using $DEV"; lsblk -no NAME,SIZE,FSTYPE,TYPE,MOUNTPOINT "$DEV"

# 1) Install ZFS (pick ONE)

# A) Stock 'linux' kernel via archzfs repo (prebuilt, recommended)
# sudo pacman -S --needed archlinux-keyring
# sudo tee -a /etc/pacman.conf >/dev/null <<'EOF'
# [archzfs]
# Server = https://archzfs.com/$repo/x86_64
# EOF
# sudo pacman -Sy --needed zfs-linux zfs-utils

# B) DKMS path (works with custom kernels; needs headers)
sudo pacman -S --needed base-devel linux-headers
yay -S --needed zfs-dkms zfs-utils

# Load the module
sudo modprobe zfs


# ── 0) Choose target partition (you have nvme0n1p5 free) ────────────────
DEV=/dev/nvme0n1p5
lsblk -no NAME,SIZE,FSTYPE,TYPE,MOUNTPOINT "$DEV"

# ── 1) Install ZFS (choose ONE path) ───────────────────────────────────
# A) DKMS path (works across kernels; ensure headers)
sudo pacman -S --needed base-devel linux-headers
yay -S --needed zfs-dkms zfs-utils

# (OR) B) Prebuilt for stock kernel (archzfs repo) — if you prefer
# echo -e '\n[archzfs]\nServer = https://archzfs.com/$repo/x86_64' | sudo tee -a /etc/pacman.conf
# sudo pacman -Sy --needed zfs-linux zfs-utils

# ── 2) Load module now and on boot ─────────────────────────────────────
sudo modprobe zfs
echo zfs | sudo tee /etc/modules-load.d/zfs.conf >/dev/null

# ── 3) Mark the GPT type for clarity (bf01 = Solaris/ZFS) ──────────────
DISK="/dev/$(lsblk -no pkname "$DEV")"
PARTNO="$(cat /sys/class/block/$(basename "$DEV")/partition)"
sudo sgdisk -t ${PARTNO}:bf01 "$DISK"

# ── 4) Wipe signatures (DANGEROUS: removes any old fs on $DEV) ─────────
sudo wipefs -a "$DEV"

# ── 5) Create a single-device pool with sane NVMe defaults ─────────────
POOL=tank
sudo zpool create -f -o ashift=12 -o autotrim=on \
  -O compression=zstd -O xattr=sa -O acltype=posixacl -O atime=off \
  -O normalization=formD -O mountpoint=none \
  "$POOL" "$DEV"

# ── 6) Datasets and mountpoints ────────────────────────────────────────
sudo zfs create -o mountpoint=/tank       "$POOL"/root
sudo zfs create -o mountpoint=/tank/Work  "$POOL"/Work
sudo zfs create -o mountpoint=/tank/Books "$POOL"/Books
sudo zfs create -o mountpoint=/tank/Ref   "$POOL"/Reference

# Optional encrypted sub-dataset for secrets
sudo zfs create -o encryption=aes-256-gcm -o keyformat=passphrase \
                -o keylocation=prompt -o mountpoint=/tank/secure \
                "$POOL"/secure

# ── 7) Persist import/mount on boot ────────────────────────────────────
# Cache the pool topology and enable ZFS services
sudo zpool set cachefile=/etc/zfs/zpool.cache "$POOL"
sudo systemctl enable --now zfs.target zfs-import-cache.service zfs-mount.service zfs-zed.service

# ── 8) Basic ownership so you can write under /tank ────────────────────
sudo chown -R "$USER":"$USER" /tank


sudo zfs create -V 16G -b 4096 -o compression=off \
  -o logbias=throughput -o sync=always \
  -o primarycache=metadata -o secondarycache=none \
  "$POOL"/swap
sudo mkswap /dev/zvol/"$POOL"/swap
echo "/dev/zvol/${POOL}/swap none swap defaults,pri=50 0 0" | sudo tee -a /etc/fstab
sudo swapon -a

# Create a simple systemd timer for monthly scrub
sudo tee /etc/systemd/system/zpool-scrub@.service >/dev/null <<'EOF'
[Unit]
Description=ZFS scrub on pool %i

[Service]
Type=oneshot
ExecStart=/usr/bin/zpool scrub %i
EOF

sudo tee /etc/systemd/system/zpool-scrub@.timer >/dev/null <<'EOF'
[Unit]
Description=Monthly ZFS scrub on pool %i

[Timer]
OnCalendar=monthly
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl enable --now zpool-scrub@tank.timer


# Pool import/mount
zpool status
zfs list -o name,used,avail,refer,mountpoint
# Services
systemctl is-enabled zfs-import-cache.service zfs-mount.service zfs-zed.service
# TRIM
zpool get autotrim "$POOL"
# Ownership and write test
touch /tank/testfile && ls -l /tank/testfile


