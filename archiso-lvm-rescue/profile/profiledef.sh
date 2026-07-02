#!/usr/bin/env bash
# shellcheck disable=SC2034

iso_name="heini-arch-lvm-rescue"
iso_label="HLVM_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="Heini <local custom ArchISO>"
iso_application="Arch Linux LVM rescue live ISO"
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
install_dir="arch"
buildmodes=('iso')
bootmodes=('bios.syslinux'
           'uefi.systemd-boot')
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')
bootstrap_tarball_compression=('zstd' '-c' '-T0' '--auto-threads=logical' '--long' '-19')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/root/.automated_script.sh"]="0:0:755"
  ["/root/.gnupg"]="0:0:700"
  ["/usr/local/bin/choose-mirror"]="0:0:755"
  ["/usr/local/bin/Installation_guide"]="0:0:755"
  ["/usr/local/bin/livecd-sound"]="0:0:755"
  ["/root/lvm-scripts"]="0:0:755"
  ["/root/lvm-scripts/lvm-math-inspect.sh"]="0:0:755"
  ["/root/lvm-scripts/lvm-organize-resize-logical-partitions.sh"]="0:0:755"
  ["/root/lvm-scripts/lvm_resize.sh"]="0:0:755"
  ["/root/lvm-scripts/lvm_resize2.sh"]="0:0:755"
  ["/usr/local/bin/lvm-math-inspect"]="0:0:755"
  ["/usr/local/bin/lvm-move-space-safe"]="0:0:755"
)
