#!/usr/bin/env bash

echo "signing keys for [chaotic-aur]"
sudo pacman-key -r FBA220DFC880C036
sudo pacman-key --lsign-key FBA220DFC880C036
sudo pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com
sudo pacman-key --lsign-key 3056513887B78AEB
yes | sudo pacman -U 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst'
yes | sudo pacman -U 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'

echo "signing keys for [arch4edu]"
sudo pacman-key -r 7931B6D628C8D3BA
sudo pacman-key --lsign-key 7931B6D628C8D3BA

# pacman-key --recv-keys 7931B6D628C8D3BA
# pacman-key --finger 7931B6D628C8D3BA
# pacman-key --lsign-key 7931B6D628C8D3BA
echo "fetching arch4edu keyring"
curl -O https://mirrors.tuna.tsinghua.edu.cn/arch4edu/any/arch4edu-keyring-20200805-1-any.pkg.tar.zst
yes | sudo pacman -U arch4edu-keyring-20200805-1-any.pkg.tar.zst

sudo pacman-key -r B1F96021DB62254D
sudo pacman-key --lsign-key B1F96021DB62254D

sudo pacman -Syyy

echo "uncommenting [chaotic-aur] in /etc/pacman.conf"
sudo sed -i \
  '/^\s*# \[chaotic-aur\]/,/^\s*# Key-ID:/ s/^\s*# //' \
  /etc/pacman.conf

echo "uncommenting [bioarchlinux] in /etc/pacman.conf"
sudo sed -i \
  '/^\s*# \[bioarchlinux\]/,/^\s*# Key-ID:/ s/^\s*# //' \
  /etc/pacman.conf

echo "uncommenting [arch4edu] in /etc/pacman.conf"
sudo sed -i \
  '/^\s*# \[arch4edu\]/,/^\s*# Key-ID:/ { /^\s*# Key-ID:/! s/^\s*# // }' \
  /etc/pacman.conf
