#!/bin/bash

# Set variables for user and group setup
USER="heini"
GROUP="wheel"
HOME_DIR="/home/$USER"
SUDOERS_FILE="/etc/sudoers"

# 1. Create the user and add to 'wheel' group
useradd -m -G $GROUP -s /bin/bash $USER

# 2. Set password for the user (you can customize this or make it interactive)
echo "$USER:password" | chpasswd

# 3. Edit sudoers file to grant 'wheel' group NOPASSWD access
if ! grep -q "%wheel" $SUDOERS_FILE; then
    echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" >> $SUDOERS_FILE
fi

# 4. Switch to user 'heini' and install necessary packages
sudo -u $USER bash << EOF
    # Update mirrors and install required packages
    sudo pacman -Syy
    sudo pacman -S --noconfirm git reflector rsync yay paru

    # Clone repositories
    git clone https://github.com/Epineph/UserScripts $HOME_DIR/repos/UserScripts
    git clone https://github.com/Epineph/nvim_conf $HOME_DIR/repos/nvim_conf
    git clone https://github.com/Epineph/my_zshrc $HOME_DIR/repos/my_zshrc
    git clone https://github.com/Epineph/generate_install_command $HOME_DIR/repos/generate_install_command
    git clone https://aur.archlinux.org/yay.git $HOME_DIR/repos/yay
    git clone https://aur.archlinux.org/paru.git $HOME_DIR/repos/paru
    git clone https://github.com/JaKooLit/Arch-Hyprland $HOME_DIR/repos/Arch-Hyprland

    # Change ownership to 'heini'
    sudo chown -R $USER:$GROUP $HOME_DIR/repos/

    # Copy scripts to /usr/local/bin
    sudo cp $HOME_DIR/repos/UserScripts/convenient_scripts/chPerms.sh /usr/local/bin/chPerms
    sudo cp $HOME_DIR/repos/UserScripts/linux_conf_scripts/reflector.sh /usr/local/bin/update_mirrors
    sudo cp $HOME_DIR/repos/UserScripts/log_scripts/gen_log.sh /usr/local/bin/gen_log
    sudo cp $HOME_DIR/repos/UserScripts/building_scripts/build_repository_v2.sh /usr/local/bin/build_repo

    # Set permissions for scripts
    sudo chmod -R 777 /usr/local/bin

    # Modify .bashrc
    echo "export PATH=/usr/local/bin:\$HOME/.cargo/bin:\$HOME/bin:\$HOME/repos/vcpkg:\$PATH" >> $HOME_DIR/.bashrc
    source $HOME_DIR/.bashrc
EOF

# 5. Ensure proper ownership and permissions for /usr/local/bin
sudo chown -R $USER:$GROUP /usr/local/bin
sudo chmod -R 777 /usr/local/bin

echo "Setup complete for user $USER"
