#!/bin/bash

################################################################################
# Set up the environment for the ISO creation                                  #
################################################################################
USER_DIR="/home/$USER"
BUILD_DIR="$USER_DIR/builtPackages"
ISO_HOME="$USER_DIR/ISOBUILD/custom_iso"
ISO_LOCATION="$ISO_HOME/ISOOUT/"
AUR_HELPER_DIR="$AUR_HELPER_DIR"

# Ensure the ISO build directory exists
mkdir -p "$USER_DIR/ISOBUILD"
cp -r /usr/share/archiso/configs/releng $USER_DIR/ISOBUILD/
mv $USER_DIR/ISOBUILD/releng $ISO_HOME

# Install necessary packages
pacman_packages=("archiso" "archinstall" "arch-install-scripts" "github-cli" "git" "rsync" "reflector" "clonezilla" "fd" "bat" "fzf" "yay")

check_and_install_packages() {
  for package in "$@"; do
    if ! pacman -Qi "$package" &> /dev/null; then
      sudo pacman -S --noconfirm "$package"
    fi
  done
}

check_and_install_packages "${pacman_packages[@]}"

################################################################################
# Enter the chroot environment                                                 #
################################################################################

# Prepare the chroot environment
sudo mount --bind /dev $ISO_HOME/airootfs/dev
sudo mount --bind /proc $ISO_HOME/airootfs/proc
sudo mount --bind /sys $ISO_HOME/airootfs/sys

# Chroot into the ISO
sudo chroot $ISO_HOME/airootfs /bin/bash <<EOF

# Initialize and populate pacman keys
sudo pacman-key --init
sudo pacman-key --populate archlinux

# Uncomment ParallelDownloads and multilib
sed -i '/ParallelDownloads/s/^#//' /etc/pacman.conf
sed -i '/\[multilib\]/{n;s/^#//}' /etc/pacman.conf

# Set root password
echo "root:your_root_password_here" | chpasswd

# Add user 'heini' and set password
useradd -m -G wheel -g users -s /bin/bash heini
echo "heini:your_user_password_here" | chpasswd

# Configure sudoers
echo "heini ALL=(ALL:ALL) NOPASSWD: ALL" | EDITOR='tee -a' visudo

# Configure SSH
cat << 'SSH_CONFIG' > /etc/ssh/sshd_config
Include /etc/ssh/sshd_config.d/*.conf
Port 22
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication yes
AllowAgentForwarding yes
AllowTcpForwarding yes
GatewayPorts yes
X11Forwarding yes
PermitTTY yes
TCPKeepAlive yes
PermitUserEnvironment yes
PermitTunnel yes
Subsystem sftp /usr/lib/ssh/sftp-server
SSH_CONFIG

# Setup .bashrc for user 'heini'
cat << 'BASHRC_CONTENT' > /home/heini/.bashrc
#
# ~/.bashrc
#

# If not running interactively, don't do anything
[[ \$- != *i* ]] && return

alias ls='ls --color=auto'
alias grep='grep --color=auto'
PS1='[\u@\h \W]\$ '

export LANGUAGE=en_DK.UTF-8
export LC_ALL=C.UTF-8

export CARGO_BIN=\$HOME/.cargo/bin
export HOME_LOCBIN=\$HOME/.local/bin
export LOCBIN=/usr/local/bin
export HOME_BIN=\$HOME/bin
export HOME_BINBIN=\$HOME/bin/bin
export VCPKG_BIN=\$HOME/repos/vcpkg

export PATH=\$LOCBIN:\$HOME_BINBIN:\$VCPKG_BIN:\$HOME_BIN:\$HOME_LOCBIN:\$CARGO_BIN:\$PATH

[ -f ~/.fzf.bash ] && source ~/.fzf.bash

function chowd() {
    sudo chown -R heini \$1
    sudo chmod -R u+rwx \$1
}

alias bashFresh='source \$HOME/.bashrc'

source \$HOME/.bashrc
BASHRC_CONTENT

# Switch to user 'heini' and setup environment
sudo -u heini bash << 'USER_COMMANDS'
#!/bin/bash

################################################################################
# Set up the environment for the ISO creation                                  #
################################################################################
USER_DIR="/home/$USER"
BUILD_DIR="$USER_DIR/builtPackages"
ISO_HOME="$USER_DIR/ISOBUILD/custom_iso"
ISO_LOCATION="$ISO_HOME/ISOOUT/"
AUR_HELPER_DIR="$AUR_HELPER_DIR"

# Ensure the ISO build directory exists
mkdir -p "$USER_DIR/ISOBUILD"
cp -r /usr/share/archiso/configs/releng $USER_DIR/ISOBUILD/
mv $USER_DIR/ISOBUILD/releng $ISO_HOME

# Install necessary packages
pacman_packages=("archiso" "archinstall" "arch-install-scripts" "github-cli" "git" "rsync" "reflector" "clonezilla" "fd" "bat" "fzf" "yay")

check_and_install_packages() {
  for package in "$@"; do
    if ! pacman -Qi "$package" &> /dev/null; then
      sudo pacman -S --noconfirm "$package"
    fi
  done
}

check_and_install_packages "${pacman_packages[@]}"

################################################################################
# Enter the chroot environment                                                 #
################################################################################

# Prepare the chroot environment
sudo mount --bind /dev $ISO_HOME/airootfs/dev
sudo mount --bind /proc $ISO_HOME/airootfs/proc
sudo mount --bind /sys $ISO_HOME/airootfs/sys

# Chroot into the ISO
sudo chroot $ISO_HOME/airootfs /bin/bash <<EOF

# Initialize and populate pacman keys
sudo pacman-key --init
sudo pacman-key --populate archlinux

# Uncomment ParallelDownloads and multilib
sed -i '/ParallelDownloads/s/^#//' /etc/pacman.conf
sed -i '/\[multilib\]/{n;s/^#//}' /etc/pacman.conf

# Set root password
echo "root:your_root_password_here" | chpasswd

# Add user 'heini' and set password
useradd -m -G wheel -g users -s /bin/bash heini
echo "heini:your_user_password_here" | chpasswd

# Configure sudoers
echo "heini ALL=(ALL:ALL) NOPASSWD: ALL" | EDITOR='tee -a' visudo

# Configure SSH
cat << 'SSH_CONFIG' > /etc/ssh/sshd_config
Include /etc/ssh/sshd_config.d/*.conf
Port 22
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication yes
AllowAgentForwarding yes
AllowTcpForwarding yes
GatewayPorts yes
X11Forwarding yes
PermitTTY yes
TCPKeepAlive yes
PermitUserEnvironment yes
PermitTunnel yes
Subsystem sftp /usr/lib/ssh/sftp-server
SSH_CONFIG

# Setup .bashrc for user 'heini'
cat << 'BASHRC_CONTENT' > /home/heini/.bashrc
#
# ~/.bashrc
#

# If not running interactively, don't do anything
[[ \$- != *i* ]] && return

alias ls='ls --color=auto'
alias grep='grep --color=auto'
PS1='[\u@\h \W]\$ '

export LANGUAGE=en_DK.UTF-8
export LC_ALL=C.UTF-8

export CARGO_BIN=\$HOME/.cargo/bin
export HOME_LOCBIN=\$HOME/.local/bin
export LOCBIN=/usr/local/bin
export HOME_BIN=\$HOME/bin
export HOME_BINBIN=\$HOME/bin/bin
export VCPKG_BIN=\$HOME/repos/vcpkg

export PATH=\$LOCBIN:\$HOME_BINBIN:\$VCPKG_BIN:\$HOME_BIN:\$HOME_LOCBIN:\$CARGO_BIN:\$PATH

[ -f ~/.fzf.bash ] && source ~/.fzf.bash

function chowd() {
    sudo chown -R heini \$1
    sudo chmod -R u+rwx \$1
}

function Set-Location() {
  if [ ! -d "$1" ]; then
  echo "Location "$1" cannot be found. Creating it..."
  mkdir -p $HOME
  "
  local ChangeToDir=
# Change ownership and permissions of the home directory
sudo chown -R heini:heini /home/heini
sudo chmod -R u+rwx /home/heini

}

alias bashFresh='source \$HOME/.bashrc'

BASHRC_CONTENT
sudo -u heini bas << 'USER_COMMANDS'

# Change ownership and permissions of the home directory


sudo chown -R heini:heini /home/heini
sudo chmod -R u+rwx /home/heini
source $HOME/.bashrc
# Switch to user 'heini' and setup environment
sudo -u heini bash << 'USER_COMMANDS'
mkdir -p /home/heini/repos
cd /home/heini/repos
git clone https://github.com/Epineph/UserScripts
git clone https://github.com/Epineph/generate_install_command

sudo cp UserScripts/convenient_scripts/chPerms.sh /usr/local/bin/chPerms
sudo cp UserScripts/linux_conf_scripts/reflector.sh /usr/local/bin/update_mirrors
sudo cp UserScripts/log_scripts/gen_log.sh /usr/local/bin/gen_log
sudo cp UserScripts/building_scripts/build_repository_v2.sh /usr/local/bin/build_repo

sudo chown -R heini:heini /usr/local/bin

sudo chPerms /home/heini -R -o heini:heini -p u=rwx,g=r-x,o=r-x --noconfirm
bashFresh
USER_COMMANDS


mkdir -p /home/heini/repos
cd /home/heini/repos

git clone https://github.com/Epineph/UserScripts
git clone https://github.com/Epineph/generate_install_command

sudo cp UserScripts/convenient_scripts/chPerms.sh /usr/local/bin/chPerms
sudo cp UserScripts/linux_conf_scripts/reflector.sh /usr/local/bin/update_mirrors
sudo cp UserScripts/log_scripts/gen_log.sh /usr/local/bin/gen_log
sudo cp UserScripts/building_scripts/build_repository_v2.sh /usr/local/bin/build_repo

sudo chown -R heini:heini /usr/local/bin

sudo chPerms /home/heini -R -o heini:heini -p u=rwx,g=r-x,o=r-x --noconfirm
bashFresh
USER_COMMANDS

EOF

# Exit chroot
sudo umount $ISO_HOME/airootfs/dev
sudo umount $ISO_HOME/airootfs/proc
sudo umount $ISO_HOME/airootfs/sys

################################################################################
# Final steps for the ISO build
################################################################################

# Continue with the rest of the ISO build process if necessary.

