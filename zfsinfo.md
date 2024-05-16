## Arch Linux Root on ZFS

Installation steps for running Arch Linux with root on ZFS using UEFI and ```systemd-boot```. All steps are run as ```root```.

Requires an Arch Linux image with ZFS built-in (see [References](#References)).

### In live environment

If using KVM, add a *Serial* number for each virtual disk and reboot the VM. The disks should now be available in `/dev/disk/by-id` as `virtio-<Serial>`.

- Set a bigger font if needed:

```
setfont latarcyrheb-sun32
```

- To setup Wi-Fi, add the *ESSID* and passphrase:
```
 wpa_passphrase ESSID PASSPHRASE > /etc/wpa_supplicant/wpa_supplicant.conf
```

- Start *wpa_supplicant* and get an IP address:

```
wpa_supplicant -B -c /etc/wpa_supplicant/wpa_supplicant.conf -i <wifi interface>
dhclient <wifi interface>
```

- Wipe disks, create *boot*, *swap* and ZFS partitions:

```
sgdisk --zap-all /dev/disk/by-id/<disk0>
sgdisk -n1:0:+512M -t1:ef00 /dev/disk/by-id/<disk0>
sgdisk -n2:0:+8G -t2:8200 /dev/disk/by-id/<disk0>
sgdisk -n3:0:+210G -t3:bf00 /dev/disk/by-id/<disk0>

sgdisk --zap-all /dev/disk/by-id/<disk1>
sgdisk -n1:0:+512M -t1:ef00 /dev/disk/by-id/<disk1>
sgdisk -n2:0:+8G -t2:8200 /dev/disk/by-id/<disk1>
sgdisk -n3:0:+210G -t3:bf00 /dev/disk/by-id/<disk1>
```
You can also use a ```zvol``` for swap, but see [this](https://wiki.archlinux.org/index.php/ZFS#Swap_volume) first.

- Format boot and swap partitions
```
mkfs.vfat /dev/disk/by-id/<disk0>-part1
mkfs.vfat /dev/disk/by-id/<disk1>-part1

mkswap /dev/disk/by-id/<disk0>-part2
mkswap /dev/disk/by-id/<disk1>-part2
```
- Create swap
```
swapon /dev/disk/by-id/<disk0>-part2 /dev/disk/by-id/<disk1>-part2
```

- On choosing ```ashift```

*You should specify an ashift when that value is too low for what you actually need, either today (disk lies) or into the future (replacement disks will be AF)*. Looks like a sound advice to me. If in doubt, [clarify](https://jrs-s.net/2018/08/17/zfs-tuning-cheat-sheet/) before going any further.

Disk block size check:
```
cat /sys/class/block/<disk>/queue/{phys,log}ical_block_size
```

- Create pool (here's for a RAID 0 equivalent, all-flash drives):
```
zpool create \
    -o ashift=12 \
    -o autotrim=on \
    -O relatime=on \
    -O acltype=posixacl -O canmount=off -O compression=lz4 \
    -O dnodesize=legacy -O normalization=formD \
    -O xattr=sa -O devices=off -O mountpoint=none -R /mnt rpool /dev/disk/by-id/<disk0>-part3 /dev/disk/by-id/<disk1>-part3
```

If the pool is larger than 10 disks you should identify them ```by-path``` or ```by-vdev``` (see [here](https://openzfs.github.io/openzfs-docs/Project%20and%20Community/FAQ.html#selecting-dev-names-when-creating-a-pool-linux) for more details).

Check ```ashift``` with:

```
zdb -C | grep ashift
```

- Create datasets:
```
zfs create -o canmount=off -o mountpoint=none rpool/ROOT
zfs create -o mountpoint=/ -o canmount=noauto rpool/ROOT/default
zfs create -o mountpoint=none rpool/DATA
zfs create -o mountpoint=/home rpool/DATA/home
zfs create -o mountpoint=/root rpool/DATA/home/root
zfs create -o mountpoint=/local rpool/DATA/local
zfs create -o mountpoint=none rpool/DATA/var
zfs create -o mountpoint=/var/log rpool/DATA/var/log # after a rollback, systemd-journal blocks at reboot without this dataset
```

- Create swap (not needed if you have dedicated partitions, like above)

```
zfs create -V 16G -b $(getconf PAGESIZE) -o compression=zle -o logbias=throughput -o sync=always -o primarycache=metadata -o secondarycache=none -o com.sun:auto-snapshot=false rpool/swap
mkswap /dev/zvol/rpool/swap
```

- Unmount all
```
zfs umount -a
rm -rf /mnt/*
```

- Export, then import pool:
```
zpool export rpool
zpool import -d /dev/disk/by-id -R /mnt rpool -N
```

- Mount root, then the other datasets:
```
zfs mount rpool/ROOT/default
zfs mount -a
```

- Mount boot partition:
```
mkdir /mnt/boot
mount /dev/disk/by-id/<disk0>-part1 /mnt/boot
```

- Generate `fstab`:
```
mkdir /mnt/etc
genfstab -U /mnt >> /mnt/etc/fstab
```

- Add swap (not needed if you created swap partitions, like above):
```
echo "/dev/zvol/rpool/swap    none       swap  discard                    0  0" >> /mnt/etc/fstab
```

- Install the base system:
```
pacstrap /mnt base base-devel linux linux-firmware vim
```
If it fails, add GPG keys (see bellow).

- Change root into the new system:
```
arch-chroot /mnt
```
### In chroot

- Remove all lines in ```/etc/fstab```, leaving only the entries for ```swap``` and ```boot```; for `boot`, change `fmask` and `dmask` to `0077`.

- Add ZFS repository in ```/etc/pacman.conf```:
```
[archzfs]
Server = https://archzfs.com/$repo/x86_64
```

- Add GPG keys:
```
curl -O https://archzfs.com/archzfs.gpg
pacman-key -a archzfs.gpg
pacman-key --lsign-key DDF7DB817396A49B2A2723F7403BD972F75D9D76
pacman -Syy
```

- Configure time zone (change accordingly):
```
ln -sf /usr/share/zoneinfo/Region/City /etc/localtime
hwclock --systohc
```

- Generate locale (change accordingly):
```
sed -i 's/#\(en_US\.UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
```

- Configure **vconsole**, **hostname**, **hosts**:
```
echo -e "KEYMAP=us\n#FONT=latarcyrheb-sun32" > /etc/vconsole.conf
echo al-zfs > /etc/hostname
echo -e "127.0.0.1 localhost\n::1 localhost" >> /etc/hosts
```

- Set root password

- Install ZFS, microcode etc:
```
pacman -Syu archzfs-linux amd-ucode networkmanager sudo openssh rsync borg
```
Choose the default option (`all`) for the *archzfs* group.

For Intel processors install ```intel-ucode``` instead of ```amd-ucode```.

- Generate host id:
```
zgenhostid $(hostid)
```

- Create cache file:
```
zpool set cachefile=/etc/zfs/zpool.cache rpool
```

- Configure initial ramdisk in ```/etc/mkinitcpio.conf``` by removing `fsck` and adding `zfs` after `keyboard`:

<pre><code>HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block <b>zfs</b> filesystems)</code></pre>

Regenerate environment:
```
mkinitcpio -p linux
```

- Enable ZFS services:
```
systemctl enable zfs.target
systemctl enable zfs-import-cache.service
systemctl enable zfs-mount.service
systemctl enable zfs-import.target
```

- Install the bootloader:
```
bootctl --path=/boot install
```
- Add an EFI boot manager update hook in */etc/pacman.d/hooks/100-systemd-boot.hook*:
```
[Trigger]
Type = Package
Operation = Upgrade
Target = systemd

[Action]
Description = update systemd-boot
When = PostTransaction
Exec = /usr/bin/bootctl update
```

- Replace content of */boot/loader/loader.conf* with:
```
default arch
timeout 3
# bigger boot menu on a 4K laptop display
#console-mode 1
```
- Create a */boot/loader/entries/**arch**.conf* containing:
```
title Arch Linux
linux /vmlinuz-linux
initrd /amd-ucode.img
initrd /initramfs-linux.img
options zfs=rpool/ROOT/default rw
```
If using an Intel processor, replace ```/amd-ucode.img``` with ```/intel-ucode.img```.
- Exit and unmount all:
```
exit
zfs umount -a
umount -R /mnt
```

- *Export pool*:
```
zpool export rpool
```

- Reboot

A minimal Arch Linux system with root on ZFS should now be configured.

### Create user

```
zfs create -o mountpoint=/home/user rpool/DATA/home/user
groupadd -g 1234 group
useradd -g group -u 1234 -d /home/user -s /bin/bash user
cp /etc/skel/.bash* /home/user
chown -R user:group /home/user && chmod 700 /home/user
```

---

### Create additional pools and datasets

```
zpool create \
    -O atime=off \
    -O acltype=posixacl -O canmount=off -O compression=lz4 \
    -O dnodesize=auto \
    -O xattr=sa -O devices=off -O mountpoint=none pool:a /dev/disk/by-id/<disk2> /dev/disk/by-id/<disk3>

zpool create \
    -O atime=off \
    -O acltype=posixacl -O canmount=off -O compression=lz4 \
    -O dnodesize=auto \
    -O xattr=sa -O devices=off -O mountpoint=none pool:b mirror /dev/disk/by-id/<disk4> /dev/disk/by-id/<disk5> mirror /dev/disk/by-id/<disk6> /dev/disk/by-id/<disk7>
```

Create datasets:

```
zfs create -o canmount=off -o mountpoint=none pool:a/DATA
zfs create -o mountpoint=/path pool:a/DATA/path
zfs create -o mountpoint=/path/games -o recordsize=1M pool:a/DATA/path/games
zfs create -o mountpoint=/path/transmission -o recordsize=1M pool:a/DATA/path/transmission
zfs create -o mountpoint=/path/backup -o compression=off pool:a/DATA/path/backup
```

### Create NFS share

Set *Domain* in ```idmapd.conf``` on server and clients.
```
zfs set sharenfs=rw=@10.0.0.0/24 pool:a/DATA/path/name
systemctl enable nfs-server.service zfs-share.service --now
```
### Increase the capacity of a mirrored `vdev`

The following steps will replace all the disks in a mirrored `vdev` with larger ones.

Before upgrade:

```
zpool status lpool
  pool: lpool
 state: ONLINE
  scan: scrub repaired 0B in 00:02:18 with 0 errors on Tue Oct 17 15:52:42 2023
config:

        NAME                                                      STATE     READ WRITE CKSUM
        lpool                                                     ONLINE       0     0     0
          mirror-0                                                ONLINE       0     0     0
            nvme-Samsung_SSD_970_EVO_500GB_S466NB0K683727V-part1  ONLINE       0     0     0
            nvme-Samsung_SSD_970_EVO_500GB_S466NB0K621937D-part1  ONLINE       0     0     0

errors: No known data errors

zpool list lpool             
NAME    SIZE  ALLOC   FREE  CKPOINT  EXPANDSZ   FRAG    CAP  DEDUP    HEALTH  ALTROOT
lpool   464G   218G   246G        -         -     9%    47%  1.00x    ONLINE  -
```

The `autoexpand` property on the pool should be set to `on`. 

```
zpool get autoexpand lpool
NAME   PROPERTY    VALUE   SOURCE
lpool  autoexpand  off     default
```

If it's not, set it:

```
zpool set autoexpand=on lpool
```

Power off the machine, physically replace one of drives using the same slot or cable, then power it back on. After replacing the drive, `zpool status` shows the following:

```
zpool status lpool
  pool: lpool
 state: DEGRADED 
status: One or more devices could not be used because the label is missing or
        invalid.  Sufficient replicas exist for the pool to continue
        functioning in a degraded state.
action: Replace the device using 'zpool replace'.
   see: https://openzfs.github.io/openzfs-docs/msg/ZFS-8000-4J
  scan: scrub repaired 0B in 00:02:18 with 0 errors on Tue Oct 17 15:52:42 2023
config:

        NAME                                                STATE     READ WRITE CKSUM
        lpool                                               DEGRADED     0     0     0
          mirror-0                                          DEGRADED     0     0     0
            nvme-Samsung_SSD_970_EVO_500GB_S466NB0K683727V  ONLINE       0     0     0
            3003823869835917342                             UNAVAIL      0     0     0  was /dev/disk/by-id/nvme-Samsung_SSD_970_EVO_500GB_S466NB0K621937D-part1

errors: No known data errors
```

Replace the drive in pool (here, `nvme-Samsung_SSD_970_EVO_500GB_S466NB0K621937D` is the old, now replaced drive):

```
zpool replace lpool /dev/disk/by-id/nvme-Samsung_SSD_970_EVO_500GB_S466NB0K621937D /dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_S6Z2NF0W836871V
```

The new drive is now resilvering:

```
zpool status lpool
  pool: lpool
 state: DEGRADED
status: One or more devices is currently being resilvered.  The pool will
        continue to function, possibly in a degraded state.
action: Wait for the resilver to complete.
  scan: resilver in progress since Sun Oct 29 14:09:00 2023
        144G / 218G scanned at 20.6G/s, 0B / 218G issued
        0B resilvered, 0.00% done, no estimated completion time
config:

        NAME                                                STATE     READ WRITE CKSUM
        lpool                                               DEGRADED     0     0     0
          mirror-0                                          DEGRADED     0     0     0
            nvme-Samsung_SSD_970_EVO_500GB_S466NB0K683727V  ONLINE       0     0     0
            replacing-1                                     DEGRADED     0     0     0
              3003823869835917342                           UNAVAIL      0     0     0  was /dev/disk/by-id/nvme-Samsung_SSD_970_EVO_500GB_S466NB0K621937D-part1
              nvme-Samsung_SSD_990_PRO_2TB_S6Z2NF0W836871V  ONLINE       0     0     0

errors: No known data errors
```

Wait for resilver to finish:

```
zpool status lpool
  pool: lpool
 state: ONLINE
  scan: resilvered 220G in 00:01:58 with 0 errors on Sun Oct 29 14:10:58 2023
config:

        NAME                                                STATE     READ WRITE CKSUM
        lpool                                               ONLINE       0     0     0
          mirror-0                                          ONLINE       0     0     0
            nvme-Samsung_SSD_970_EVO_500GB_S466NB0K683727V  ONLINE       0     0     0
            nvme-Samsung_SSD_990_PRO_2TB_S6Z2NF0W836871V    ONLINE       0     0     0

errors: No known data errors
```

Scrub the pool

```
zpool scrub lpool
```

and wait until it's finished:

```
zpool status lpool
  pool: lpool
 state: ONLINE
  scan: scrub repaired 0B in 00:02:04 with 0 errors on Sun Oct 29 14:16:24 2023
config:

        NAME                                                STATE     READ WRITE CKSUM
        lpool                                               ONLINE       0     0     0
          mirror-0                                          ONLINE       0     0     0
            nvme-Samsung_SSD_970_EVO_500GB_S466NB0K683727V  ONLINE       0     0     0
            nvme-Samsung_SSD_990_PRO_2TB_S6Z2NF0W836871V    ONLINE       0     0     0

errors: No known data errors
```

Physically replace the second disk using the same slot or cable; after powering on the machine, the pool is again in a degraded state:

```
zpool status lpool
  pool: lpool
 state: DEGRADED
status: One or more devices could not be used because the label is missing or
        invalid.  Sufficient replicas exist for the pool to continue
        functioning in a degraded state.
action: Replace the device using 'zpool replace'.
   see: https://openzfs.github.io/openzfs-docs/msg/ZFS-8000-4J
  scan: scrub repaired 0B in 00:02:04 with 0 errors on Sun Oct 29 14:16:24 2023
config:

        NAME                                              STATE     READ WRITE CKSUM
        lpool                                             DEGRADED     0     0     0
          mirror-0                                        DEGRADED     0     0     0
            4843306544541531925                           UNAVAIL      0     0     0  was /dev/disk/by-id/nvme-Samsung_SSD_970_EVO_500GB_S466NB0K683727V-part1
            nvme-Samsung_SSD_990_PRO_2TB_S6Z2NF0W836871V  ONLINE       0     0     0

errors: No known data errors
```

Replace the second drive in the pool:

```
zpool replace lpool /dev/disk/by-id/nvme-Samsung_SSD_970_EVO_500GB_S466NB0K683727V /dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_S6Z2NF0W932278L
```
The second drive is now resilvering:

```
zpool status lpool
  pool: lpool
 state: DEGRADED
status: One or more devices is currently being resilvered.  The pool will
        continue to function, possibly in a degraded state.
action: Wait for the resilver to complete.
  scan: resilver in progress since Sun Oct 29 14:28:24 2023
        218G / 218G scanned, 23.7G / 218G issued at 1.58G/s
        24.1G resilvered, 10.87% done, 00:02:03 to go
config:

        NAME                                                STATE     READ WRITE CKSUM
        lpool                                               DEGRADED     0     0     0
          mirror-0                                          DEGRADED     0     0     0
            replacing-0                                     DEGRADED     0     0     0
              4843306544541531925                           UNAVAIL      0     0     0  was /dev/disk/by-id/nvme-Samsung_SSD_970_EVO_500GB_S466NB0K683727V-part1
              nvme-Samsung_SSD_990_PRO_2TB_S6Z2NF0W932278L  ONLINE       0     0     0  (resilvering)
            nvme-Samsung_SSD_990_PRO_2TB_S6Z2NF0W836871V    ONLINE       0     0     0

errors: No known data errors
```

Wait for resilvering to finish:

```
zpool status lpool
  pool: lpool
 state: ONLINE
  scan: resilvered 220G in 00:02:30 with 0 errors on Sun Oct 29 14:30:54 2023
config:

        NAME                                              STATE     READ WRITE CKSUM
        lpool                                             ONLINE       0     0     0
          mirror-0                                        ONLINE       0     0     0
            nvme-Samsung_SSD_990_PRO_2TB_S6Z2NF0W932278L  ONLINE       0     0     0
            nvme-Samsung_SSD_990_PRO_2TB_S6Z2NF0W836871V  ONLINE       0     0     0

errors: No known data errors
```

Scrub pool again:

```
zpool scrub lpool && zpool status lpool
  pool: lpool
 state: ONLINE
  scan: scrub in progress since Sun Oct 29 14:31:51 2023
        218G / 218G scanned, 15.1G / 218G issued at 1.51G/s
        0B repaired, 6.91% done, 00:02:14 to go
config:

        NAME                                              STATE     READ WRITE CKSUM
        lpool                                             ONLINE       0     0     0
          mirror-0                                        ONLINE       0     0     0
            nvme-Samsung_SSD_990_PRO_2TB_S6Z2NF0W932278L  ONLINE       0     0     0
            nvme-Samsung_SSD_990_PRO_2TB_S6Z2NF0W836871V  ONLINE       0     0     0

errors: No known data errors
```
Check pool:

```
zpool status lpool
  pool: lpool
 state: ONLINE
  scan: scrub repaired 0B in 00:02:21 with 0 errors on Sun Oct 29 14:34:12 2023
config:

        NAME                                              STATE     READ WRITE CKSUM
        lpool                                             ONLINE       0     0     0
          mirror-0                                        ONLINE       0     0     0
            nvme-Samsung_SSD_990_PRO_2TB_S6Z2NF0W932278L  ONLINE       0     0     0
            nvme-Samsung_SSD_990_PRO_2TB_S6Z2NF0W836871V  ONLINE       0     0     0

errors: No known data errors
```

New pool size:

```
zpool list lpool  
NAME    SIZE  ALLOC   FREE  CKPOINT  EXPANDSZ   FRAG    CAP  DEDUP    HEALTH  ALTROOT
lpool  1.82T   218G  1.60T        -         -     2%    11%  1.00x    ONLINE  -
```
___

#### References:

1. [https://wiki.archlinux.org/index.php/Install_Arch_Linux_on_ZFS](https://wiki.archlinux.org/index.php/Install_Arch_Linux_on_ZFS)
2. [https://wiki.archlinux.org/index.php/ZFS](https://wiki.archlinux.org/index.php/ZFS)
3. [https://ramsdenj.com/2016/06/23/arch-linux-on-zfs-part-2-installation.html](https://ramsdenj.com/2016/06/23/arch-linux-on-zfs-part-2-installation.html)
4. [https://github.com/reconquest/archiso-zfs](https://github.com/reconquest/archiso-zfs)
5. [https://zedenv.readthedocs.io/en/latest/setup.html](https://zedenv.readthedocs.io/en/latest/setup.html)
6. [https://docs.oracle.com/cd/E37838_01/html/E60980/index.html](https://docs.oracle.com/cd/E37838_01/html/E60980/index.html)
7. [https://ramsdenj.com/2020/03/18/zectl-zfs-boot-environment-manager-for-linux.html](https://ramsdenj.com/2020/03/18/zectl-zfs-boot-environment-manager-for-linux.html)
8. [https://superuser.com/questions/1310927/what-is-the-absolute-minimum-size-a-uefi-partition-can-be](https://superuser.com/questions/1310927/what-is-the-absolute-minimum-size-a-uefi-partition-can-be), [https://systemd.io/9OOT_LOADER_SPECIFICATION/](https://systemd.io/BOOT_LOADER_SPECIFICATION/)
9. [OpenZFS Admin Documentation](https://openzfs.github.io/openzfs-docs/Project%20and%20Community/Admin%20Documentation.html)
10. [zfs(8)](https://openzfs.github.io/openzfs-docs/man/8/zfs.8.html)
11. [zpool(8)](https://openzfs.github.io/openzfs-docs/man/8/zpool.8.html)
12. [https://jrs-s.net/category/open-source/zfs/](https://jrs-s.net/category/open-source/zfs/)
13. [https://github.com/ewwhite/zfs-ha/wiki](https://github.com/ewwhite/zfs-ha/wiki)
14. [http://nex7.blogspot.com/2013/03/readme1st.html](http://nex7.blogspot.com/2013/03/readme1st.html)
15. [Arch Linux ZFS images](https://github.com/stevleibelt/arch-linux-live-cd-iso-with-zfs/releases)
