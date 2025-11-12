#!/usr/bin/env bash
#sudo mkdir -p /efi

# mount other partitions
#sudo mkdir -p /efi
sudo mount /dev/nvme0n1p1 /mnt/efi

sudo cp /mnt/etc/fstab.old

genstab -U /mnt > /mnt/etc/fstab

arch-chroot /mnt

sudo bootctl --path=/efi install

echo -e "default   arch-git.conf\ntimeout   5\nconsole-mode max\neditor    no" | sudo tee /efi/loader/loader.conf
default   arch-git.conf
timeout   5
console-mode max
editor    no

echo -e title   "Arch Linux (amd-git)\nlinux   /vmlinuz-linux-amd-git\ninitrd  /amd-ucode.img\ninitrd  /initramfs-linux-amd-git.img\noptions root=/dev/mapper/vglinux-root rw loglevel=3 quiet" | sudo tee /efi/loader/entries/arch-git.conf

title   Arch Linux (amd-git)
linux   /vmlinuz-linux-amd-git
initrd  /amd-ucode.img
initrd  /initramfs-linux-amd-git.img
options root=/dev/mapper/vglinux-root rw loglevel=3 quiet

echo -e "title   Arch Linux\nlinux   /vmlinuz-linux\ninitrd  /amd-ucode.img\ninitrd  /initramfs-linux.img\noptions root=/dev/mapper/vglinux-root rw loglevel=3 quiet" | sudo tee /efi/loader/entries/arch.conf

title   Arch Linux
linux   /vmlinuz-linux
initrd  /amd-ucode.img
initrd  /initramfs-linux.img
options root=/dev/mapper/vglinux-root rw loglevel=3 quiet

echo -e "title  Windows 10\nefi    /EFI/Microsoft/Boot/bootmgfw.efi" | sudo tee /efi/loader/entries/windows.conf

title  Windows 10
efi    /EFI/Microsoft/Boot/bootmgfw.efi
