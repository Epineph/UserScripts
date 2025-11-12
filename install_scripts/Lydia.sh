#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status

# Enable multilib repository and parallel downloads
sudo sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
sudo sed -i 's/^#\(ParallelDownloads = 5\)/\1/' /etc/pacman.conf

# Synchronize time
timedatectl set-ntp true

# Update mirrors and package database
pacman -Syyy

# Install required utilities
pacman -S fzf mdadm lvm2 git --needed --noconfirm

# Disk Selection
selected_disks=$(lsblk -d -o NAME,SIZE,MODEL | grep -E '^sd|^nvme' | fzf -m | awk '{print "/dev/"$1}')

# Ensure two disks are selected for RAID
if [ "$(echo "$selected_disks" | wc -l)" -lt 2 ]; then
    echo "Select at least two disks for RAID configuration."
    exit 1
fi

# Stop any existing RAID arrays
mdadm --zero-superblock --force $(for disk in $selected_disks; do echo "${disk}p2"; done)

# Wipe disks
for disk in $selected_disks; do
    wipefs --all --force $disk
done

# Partition Disks
for disk in $selected_disks; do
    echo "Partitioning $disk..."
    parted $disk --script mklabel gpt
    parted $disk --script mkpart ESP fat32 1MiB 2049MiB
    parted $disk --script set 1 esp on
    parted $disk --script mkpart primary 2049MiB 100%
done

# Ensure partitions are recognized
partprobe

# Create RAID-0 Array
echo "Setting up RAID-0 (striping) across selected disks"
partitions=$(for disk in $selected_disks; do echo "${disk}p2"; done)
mdadm --create --verbose /dev/md0 --level=0 --raid-devices=$(echo "$selected_disks" | wc -l) $partitions

# Wait for RAID array to initialize
sleep 10

# Create Physical Volumes on RAID Array
pvcreate /dev/md0

# Create Volume Group
vgcreate volgroup0 /dev/md0

# Create Logical Volumes
yes | lvcreate -L 130GB volgroup0 -n lv_root
yes | lvcreate -L 32GB volgroup0 -n lv_swap
yes | lvcreate -l 100%FREE volgroup0 -n lv_home

# Format Partitions
for disk in $selected_disks; do
    mkfs.fat -F32 ${disk}p1
done
mkfs.ext4 /dev/volgroup0/lv_root
mkfs.ext4 /dev/volgroup0/lv_home
mkswap /dev/volgroup0/lv_swap

# Mount Partitions
mount /dev/volgroup0/lv_root /mnt

mkdir -p /mnt/{boot/efi,home,proc,sys,dev,etc}
mount $(echo $selected_disks | awk '{print $1"p1"}') /mnt/boot/efi/efi
mount /dev/volgroup0/lv_home /mnt/home
swapon /dev/volgroup0/lv_swap

# Bind mount necessary filesystems


# Configure mdadm
mdadm --detail --scan | tee -a /mnt/etc/mdadm.conf

# Configure mkinitcpio
sed -i -e 's/^HOOKS=.*$/HOOKS=(base systemd udev autodetect modconf block mdadm_udev lvm2 filesystems keyboard fsck)/' /etc/mkinitcpio.conf
cp /etc/mkinitcpio.conf /mnt/etc/mkinitcpio.conf
cp /etc/pacman.conf /mnt/etc/pacman.conf


# pacstrap-ping desired disk
pacstrap -P -K /mnt base base-devel neovim networkmanager rofi feh linux linux-headers linux-firmware \
os-prober efibootmgr ntfs-3g kitty git zsh nvidia nvidia-utils nvidia-setttings intel-ucode cpupower xf86-video-nouveau \
xorg-server xorg-xinit ttf-dejavu ttf-liberation ttf-inconsolata noto-fonts gucharmap \
firefox geckodriver zip unzip unrar obs-studio adapta-gtk-theme \
pulseaudio pamixer telegram-desktop python python-pip wget nginx \
openssh xorg-xrandr noto-fonts-emoji maim imagemagick xclip \
ttf-roboto playerctl papirus-icon-theme hwloc p7zip hsetroot pdfarranger inkscape \
nemo tree man inter-font fzf mesa vulkan-radeon libva-mesa-driver mumble lvm2 \
mesa-vdpau zsh-syntax-highlighting xdotool cronie dunst entr python-dbus bind-tools gnome-keyring \
i3lock dbeaver ccache ttf-cascadia-code ttf-opensans httpie pavucontrol docker docker-compose \
mpv iotop bspwm sxhkd gitg filelight networkmanager-openvpn libreoffice sassc sshfs ufw lxde rclone pinta remmina freerdp
# generating fstab
genfstab -U /mnt >> /mnt/etc/fstab
# enabled [multilib] repo on installed system

# updating repo status
arch-chroot /mnt pacman -Syy
# setting right timezone
arch-chroot /mnt ln -sf /usr/share/zoneinfo/Europe/Denmark /etc/localtime
# enabling font presets for better font rendering
arch-chroot /mnt ln -s /etc/fonts/conf.avail/70-no-bitmaps.conf /etc/fonts/conf.d
arch-chroot /mnt ln -s /etc/fonts/conf.avail/10-sub-pixel-rgb.conf /etc/fonts/conf.d
arch-chroot /mnt ln -s /etc/fonts/conf.avail/11-lcdfilter-default.conf /etc/fonts/conf.d
arch-chroot /mnt zsh -c "echo 'export FREETYPE_PROPERTIES="truetype:interpreter-version=38"' >> /etc/profile.d/freetype2.sh"
# synchronizing timer
arch-chroot /mnt hwclock --systohc
# localizing system
arch-chroot /mnt sed -i -e 's/#en_US.UTF-8 UTF-8/en_DK.UTF-8 UTF-8/g' /etc/locale.gen
arch-chroot /mnt sed -i -e 's/#en_US ISO-8859-1/en_DK ISO-8859-1/g' /etc/locale.gen
# generating locale
arch-chroot /mnt locale-gen
# setting system language
arch-chroot /mnt echo "LANG=en_DK.UTF-8" >> /mnt/etc/locale.conf
# setting machine name
arch-chroot /mnt echo "heini" >> /mnt/etc/hostname
# setting hosts file
arch-chroot /mnt echo "127.0.0.1 localhost" >> /mnt/etc/hosts
arch-chroot /mnt echo "::1 localhost" >> /mnt/etc/hosts
arch-chroot /mnt echo "127.0.1.1 heini.localdomain heini" >> /mnt/etc/hosts
# making sudoers do sudo stuff without requiring password typing
arch-chroot /mnt sed -i -e 's/# %wheel ALL=(ALL) NOPASSWD: ALL/%wheel ALL=(ALL) NOPASSWD: ALL/g' /etc/sudoers
# add support for root lvm2 boot and make initframs for proper boot
arch-chroot /mnt sed -i -e 's/base udev/base systemd udev/g' /etc/mkinitcpio.conf

arch-chroot /mnt mkinitcpio -p linux
# setting root password
arch-chroot /mnt sudo -u root /bin/zsh -c 'echo "Insert root password: " && read root_password && echo -e "$root_password\n$root_password" | passwd root'
# making user heini
arch-chroot /mnt useradd -m -G wheel -s /bin/zsh heini
# setting heini password
arch-chroot /mnt sudo -u root /bin/zsh -c 'echo "Insert heini password: " && read heini_password && echo -e "$heini_password\n$heini_password" | passwd heini'
# installing systemd-
arch-chroot /mnt bootctl --path=/boot/efi install
# configuring heini boot entry
arch-chroot /mnt /bin/zsh -c "grep \"UUID=\" /etc/fstab | grep '/ ' | awk '{ print \$1 }' | sed -e 's/UUID=//' > .root_disk_uuid"
arch-chroot /mnt /bin/zsh -c 'touch /boot/efi/loader/entries/lydia.conf'
arch-chroot /mnt /bin/zsh -c 'echo "title lydia" >> /boot/efi/loader/entries/lydia.conf'
arch-chroot /mnt /bin/zsh -c 'echo "linux /vmlinuz-linux" >> /boot/efi/loader/entries/lydia.conf'
arch-chroot /mnt /bin/zsh -c 'echo "initrd /amd-ucode.img" >> /boot/efi/loader/entries/lydia.conf'
arch-chroot /mnt /bin/zsh -c 'echo "initrd /intel-ucode.img" >> /boot/efi/loader/entries/lydia.conf'
arch-chroot /mnt /bin/zsh -c 'echo "initrd /initramfs-linux.img quiet loglevel=3 vga=current" >> /boot/efi/loader/entries/lydia.conf'
arch-chroot /mnt /bin/zsh -c 'echo options root=\"UUID=root_disk_uuid\" rw >> /boot/efi/loader/entries/lydia.conf'
arch-chroot /mnt /bin/zsh -c 'sed -i -e "s/root_disk_uuid/$(cat .root_disk_uuid)/g" /boot/efi/loader/entries/lydia.conf'
arch-chroot /mnt /bin/zsh -c 'rm .root_disk_uuid'
# changing governor to performance
arch-chroot /mnt echo "governor='performance'" >> /mnt/etc/default/cpupower
# making services start at boot
arch-chroot /mnt systemctl enable cpupower.service
arch-chroot /mnt systemctl enable NetworkManager.service
arch-chroot /mnt systemctl enable cronie.service
arch-chroot /mnt systemctl enable sshd.service
arch-chroot /mnt systemctl enable fstrim.timer
arch-chroot /mnt systemctl enable docker.service
arch-chroot /mnt systemctl enable ufw.service
# enabling and starting DNS resolver via systemd-resolved
arch-chroot /mnt systemctl enable systemd-resolved.service
arch-chroot /mnt systemctl start systemd-resolved.service
# making bspwm default for startx for both root and heini
arch-chroot /mnt echo "exec bspwm" >> /mnt/root/.xinitrc
arch-chroot /mnt echo "exec bspwm" >> /mnt/home/heini/.xinitrc
# installing yay
arch-chroot /mnt sudo -u heini git clone https://aur.archlinux.org/yay.git /home/heini/yay_tmp_install
arch-chroot /mnt sudo -u heini /bin/zsh -c "cd /home/heini/yay_tmp_install && yes | makepkg -si"
arch-chroot /mnt rm -rf /home/heini/yay_tmp_install
# adding makepkg optimizations
arch-chroot /mnt sed -i -e 's/#MAKEFLAGS="-j2"/MAKEFLAGS=-j'$(nproc --ignore 1)'/' -e 's/-march=x86-64 -mtune=generic/-march=native/' -e 's/xz -c -z/xz -c -z -T '$(nproc --ignore 1)'/' /etc/makepkg.conf
arch-chroot /mnt sed -i -e 's/!ccache/ccache/g' /etc/makepkg.conf
# installing various packages from AUR
arch-chroot /mnt sudo -u heini yay -S polybar --noconfirm
arch-chroot /mnt sudo -u heini yay -S spotifyd spotify --noconfirm
arch-chroot /mnt sudo -u heini yay -S corrupter-bin --noconfirm
arch-chroot /mnt sudo -u heini yay -S visual-studio-code-bin --noconfirm
arch-chroot /mnt sudo -u heini yay -S archtorify-git --noconfirm
arch-chroot /mnt sudo -u heini yay -S greetd greetd-tuigreet --noconfirm
arch-chroot /mnt sudo -u heini yay -S apple-fonts --noconfirm
arch-chroot /mnt sudo -u heini yay -S picom-ibhagwan-git --noconfirm
# adding tuigreet to boot
arch-chroot /mnt systemctl enable greetd.service
# installing oh-my-zsh
arch-chroot /mnt sudo -u heini /bin/zsh -c 'cd ~ && curl -O https://raw.githubusercontent.com/robbyrussell/oh-my-zsh/master/tools/install.sh && chmod +x install.sh && RUNZSH=no ./install.sh && rm ./install.sh'
# installing vundle
arch-chroot /mnt sudo -u heini mkdir -p /home/heini/.config/nvim/bundle
arch-chroot /mnt sudo -u heini git clone https://github.com/VundleVim/Vundle.vim.git /home/heini/.config/nvim/bundle/Vundle.vim
# installing fonts
arch-chroot /mnt sudo -u heini mkdir /home/heini/fonts_tmp_folder
arch-chroot /mnt sudo -u heini sudo mkdir /usr/share/fonts/OTF/
# material icons
arch-chroot /mnt sudo -u heini /bin/zsh -c "cd /home/heini/fonts_tmp_folder && curl -o materialicons.zip https://github.com/google/material-design-icons/releases/download/3.0.1/material-design-icons-3.0.1.zip && unzip materialicons.zip"
arch-chroot /mnt sudo -u heini /bin/zsh -c "sudo cp /home/heini/fonts_tmp_folder/material-design-icons-3.0.1/iconfont/MaterialIcons-Regular.ttf /usr/share/fonts/TTF/"
# removing fonts tmp folder
arch-chroot /mnt sudo -u heini rm -rf /home/heini/fonts_tmp_folder
# installing config files
arch-chroot /mnt sudo -u heini mkdir /home/heini/GitHub
arch-chroot /mnt sudo -u heini git clone https://github.com/ilbuonmarcio/heini /home/heini/GitHub/heini
arch-chroot /mnt sudo -u heini /bin/zsh -c "chmod 700 /home/heini/GitHub/heini/install_configs.sh"
arch-chroot /mnt sudo -u heini /bin/zsh -c "cd /home/heini/GitHub/heini && ./install_configs.sh"
arch-chroot /mnt cp /home/heini/GitHub/heini/greetd.config.toml /etc/greetd/config.toml
# create folder for screenshots
arch-chroot /mnt sudo -u heini mkdir /home/heini/Screenshots
# create pictures folder, secrets folder and moving default wallpaper
arch-chroot /mnt sudo -u heini mkdir /home/heini/Pictures/
arch-chroot /mnt sudo -u heini mkdir /home/heini/.secrets/
arch-chroot /mnt sudo -u heini mkdir /home/heini/Pictures/wallpapers/
# enable features on /etc/pacman.conf file
arch-chroot /mnt sed -i -e 's/#UseSyslog/UseSyslog/g' /etc/pacman.conf
arch-chroot /mnt sed -i -e 's/#Color/Color/g' /etc/pacman.conf
arch-chroot /mnt sed -i -e 's/#TotalDownload/TotalDownload/g' /etc/pacman.conf
arch-chroot /mnt sed -i -e 's/#VerbosePkgLists/VerbosePkgLists/g' /etc/pacman.conf
# enable firefox accelerated/webrender mode for quantum engine use
arch-chroot /mnt zsh -c 'echo "MOZ_ACCELERATED=1" >> /etc/environment'
arch-chroot /mnt zsh -c 'echo "MOZ_WEBRENDER=1" >> /etc/environment'
# unmounting all mounted partitions
umount -R /mnt
# syncing disks
sync
echo ""
echo "INSTALLATION COMPLETE! enjoy :)"
echo ""
sleep 3
