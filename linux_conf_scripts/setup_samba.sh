#!/bin/bash

# Install necessary packages
sudo pacman -S samba smbclient ntfs-3g exfatprogs --noconfirm

# Backup existing smb.conf
sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.bak

# Configure Samba
sudo tee /etc/samba/smb.conf > /dev/null <<EOL
[global]
   workgroup = WORKGROUP
   server string = Arch Linux Samba Server
   netbios name = archlinux
   security = user
   map to guest = Bad User
   dns proxy = no

   # Optimize settings for Windows interoperability
   socket options = TCP_NODELAY SO_RCVBUF=65536 SO_SNDBUF=65536
   max protocol = SMB3
   min protocol = SMB2
   client min protocol = SMB2
   client max protocol = SMB3

   # Enable logging
   log file = /var/log/samba/%m.log
   max log size = 1000
   logging = file

   # Ensure that all file names are case-insensitive
   preserve case = yes
   short preserve case = yes
   default case = lower
   case sensitive = no

# Share Definitions

[shared]
   path = /mnt/shared
   browseable = yes
   writable = yes
   guest ok = yes
   create mask = 0755
   directory mask = 0755
EOL

# Create the shared directory if it doesn't exist
sudo mkdir -p /mnt/shared
sudo chmod 777 /mnt/shared

# Enable and start the Samba services
sudo systemctl enable smb nmb
sudo systemctl start smb nmb

# Configure time synchronization (optional)
sudo timedatectl set-local-rtc 1 --adjust-system-clock

# Update GRUB to ensure Windows is properly recognized
sudo grub-mkconfig -o /boot/grub/grub.cfg

# Output status
echo "Samba has been configured with optimal settings for Windows interoperability."
echo "You can access the shared folder at \\archlinux\shared from Windows."


