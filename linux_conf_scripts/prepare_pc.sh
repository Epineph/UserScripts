#!/bin/bash

# Function to detect AMD integrated graphics
detect_amd_igpu() {
    lspci | grep -i 'vga\|display\|3d' | grep -i 'amd'
}

# Update system
sudo pacman -Syu --noconfirm

# Install AUR Helper (yay)
if ! command -v yay &> /dev/null
then
    echo "Installing yay AUR helper..."
    git clone https://aur.archlinux.org/yay.git
    cd yay
    makepkg -si --noconfirm
    cd ..
    rm -rf yay
fi

# Enable multilib repository
if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
    echo "Enabling multilib repository..."
    sudo sed -i '/\[multilib\]/,/Include/s/^#//' /etc/pacman.conf
    sudo pacman -Syu --noconfirm
fi

# Install essential packages
echo "Installing essential packages..."
sudo pacman -S --noconfirm base-devel linux-headers git wget curl vim nano htop

# Install performance optimization tools
echo "Installing performance optimization tools..."
sudo pacman -S --noconfirm cpupower
sudo systemctl enable cpupower.service
sudo systemctl start cpupower.service

# Set CPU governor to performance
echo "Setting CPU governor to performance..."
echo 'GOVERNOR="performance"' | sudo tee /etc/default/cpupower
sudo cpupower frequency-set -g performance

# Install and configure microcode for AMD processors
echo "Installing AMD microcode..."
sudo pacman -S --noconfirm amd-ucode
sudo grub-mkconfig -o /boot/grub/grub.cfg

# Detect AMD integrated graphics and configure
if detect_amd_igpu; then
    echo "Configuring integrated graphics..."
    sudo pacman -S --noconfirm xf86-video-amdgpu mesa
    echo 'Section "Device"
        Identifier "AMD"
        Driver "amdgpu"
        Option "DRI" "3"
        Option "TearFree" "true"
    EndSection' | sudo tee /etc/X11/xorg.conf.d/20-amdgpu.conf
fi

# Install Wayland and Hyprland dependencies
echo "Installing Wayland and Hyprland dependencies..."
sudo pacman -S --noconfirm wayland hyprland wlroots xorg-xwayland

# Install useful software from official repositories
echo "Installing useful software..."
sudo pacman -S --noconfirm firefox vlc gimp libreoffice-fresh

# Install useful software from AUR
echo "Installing AUR packages..."
yay -S --noconfirm google-chrome spotify discord

# Configure system services
echo "Configuring system services..."
sudo systemctl enable NetworkManager.service
sudo systemctl start NetworkManager.service

echo "Configuration completed successfully. Please reboot your system for all changes to take effect."

