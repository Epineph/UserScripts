#!/bin/bash

# Function to detect NVIDIA GPU
detect_nvidia_gpu() {
    lspci | grep -i 'vga\|display\|3d' | grep -i 'nvidia'
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
sudo pacman -S --noconfirm --needed base-devel linux-headers git wget curl vim nano htop

# Install NVIDIA driver and CUDA toolkit
if detect_nvidia_gpu; then
    echo "Installing NVIDIA drivers and CUDA toolkit..."
    sudo pacman -S --noconfirm --needed nvidia-dkms nvidia-utils nvidia-settings cuda
    
    # Ensure DKMS modules are installed
    sudo dkms install nvidia/$(pacman -Q nvidia-dkms | cut -d ' ' -f 2)
    
    # Ensure the nvidia-drm modeset is enabled for Wayland
    echo "options nvidia-drm modeset=1" | sudo tee /etc/modprobe.d/nvidia-drm.conf
    sudo mkinitcpio -P

    # Regenerate GRUB config if necessary
    sudo grub-mkconfig -o /boot/grub/grub.cfg
fi

# Install and configure microcode for your CPU (AMD or Intel)
if lscpu | grep -qi "amd"; then
    echo "Installing AMD microcode..."
    sudo pacman -S --noconfirm --needed amd-ucode
elif lscpu | grep -qi "intel"; then
    echo "Installing Intel microcode..."
    sudo pacman -S --noconfirm --needed intel-ucode
fi

# Install Wayland and Hyprland dependencies
echo "Installing Wayland and Hyprland dependencies..."
sudo pacman -S --noconfirm --needed wayland hyprland wlroots xorg-xwayland

# Install useful software from official repositories
echo "Installing useful software..."
sudo pacman -S --noconfirm --needed firefox vlc gimp libreoffice-fresh

# Install useful software from AUR
echo "Installing AUR packages..."
yay -S --noconfirm --needed google-chrome spotify discord

# Configure system services
echo "Configuring system services..."
sudo systemctl enable NetworkManager.service
sudo systemctl start NetworkManager.service

# Reboot prompt
echo "Configuration completed successfully. Please reboot your system for all changes to take effect."

