#!/usr/bin/env bash

#===============================================================================
# Arch Linux Performance Optimization Script
#
# This script optimizes Arch Linux installations running Wayland (Hyprland)
# on AMD Ryzen CPUs and AMD Radeon GPUs (amdgpu).
#
# Author   : Heini Winther Johnsen
# Version  : 1.0.0
# License  : MIT
#===============================================================================

set -e

#-----------------------------
# Help Section
#-----------------------------
show_help() {
cat << EOF
Arch Linux AMD Performance Optimization Script

Usage: $(basename "$0") [OPTIONS]

Options:
  -h, --help         Show this help message and exit
  -g, --gpu          Enable AMD GPU OverDrive
  -c, --cpu          Set CPU governor to performance
  -z, --zram         Enable and configure ZRAM
  -s, --scheduler    Optimize NVMe I/O scheduler
  -k, --kernel       Apply kernel performance tweaks
  -a, --all          Apply all optimizations

Examples:
  $(basename "$0") --all           # Apply all optimizations
  $(basename "$0") -g -c           # GPU OverDrive & CPU performance governor

EOF
}

#-----------------------------
# GPU OverDrive
#-----------------------------
enable_gpu_overdrive() {
  echo "Enabling AMD GPU OverDrive..."
  GRUB_CFG="/etc/default/grub"
  if ! grep -q "amdgpu.ppfeaturemask=0xfff7ffff" "$GRUB_CFG"; then
    sudo sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="amdgpu.ppfeaturemask=0xfff7ffff /' "$GRUB_CFG"
    sudo grub-mkconfig -o /boot/grub/grub.cfg
    echo "AMD GPU OverDrive enabled. Reboot required."
  else
    echo "AMD GPU OverDrive already enabled."
  fi
}

#-----------------------------
# CPU Governor Performance Mode
#-----------------------------
set_cpu_governor() {
  echo "Setting CPU governor to performance mode..."
  if command -v cpupower &>/dev/null; then
    sudo cpupower frequency-set -g performance
    sudo systemctl enable --now cpupower.service
  else
    echo "Installing cpupower..."
    sudo pacman -Sy --noconfirm cpupower
    sudo cpupower frequency-set -g performance
    sudo systemctl enable --now cpupower.service
  fi
}

#-----------------------------
# ZRAM configuration
#-----------------------------
configure_zram() {
  echo "Configuring ZRAM (compressed RAM swap)..."
  if ! pacman -Qs zram-generator &>/dev/null; then
    sudo pacman -Sy --noconfirm zram-generator
  fi

  sudo bash -c 'cat > /etc/systemd/zram-generator.conf << EOF
[zram0]
zram-size = ram * 0.5
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF'

  sudo systemctl daemon-reload
  sudo systemctl enable --now systemd-zram-setup@zram0.service
  echo "ZRAM configured and enabled."
}

#-----------------------------
# NVMe Scheduler Optimization
#-----------------------------
optimize_scheduler() {
  echo "Optimizing NVMe I/O scheduler..."
  sudo bash -c 'echo "ACTION==\"add|change\", KERNEL==\"nvme[0-9]*n[0-9]*\", ATTR{queue/scheduler}=\"none\"" > /etc/udev/rules.d/60-nvme-scheduler.rules'
  sudo udevadm control --reload-rules
  sudo udevadm trigger
  echo "NVMe scheduler optimized."
}

#-----------------------------
# Kernel Parameters Optimization
#-----------------------------
optimize_kernel_params() {
  echo "Applying kernel performance tweaks..."
  SYSCTL_CFG="/etc/sysctl.d/99-performance-tweaks.conf"
  sudo bash -c "cat > $SYSCTL_CFG" << EOF
vm.swappiness=10
vm.dirty_ratio=15
vm.dirty_background_ratio=5
kernel.sched_cfs_bandwidth_slice_us=3000
kernel.sched_latency_ns=6000000
kernel.sched_min_granularity_ns=750000
kernel.sched_wakeup_granularity_ns=1000000
EOF

  sudo sysctl --system
  echo "Kernel performance tweaks applied."
}

#-----------------------------
# Main execution
#-----------------------------
if [[ $# -eq 0 ]]; then
  show_help
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      show_help
      exit 0
      ;;
    -g|--gpu)
      enable_gpu_overdrive
      ;;
    -c|--cpu)
      set_cpu_governor
      ;;
    -z|--zram)
      configure_zram
      ;;
    -s|--scheduler)
      optimize_scheduler
      ;;
    -k|--kernel)
      optimize_kernel_params
      ;;
    -a|--all)
      enable_gpu_overdrive
      set_cpu_governor
      configure_zram
      optimize_scheduler
      optimize_kernel_params
      ;;
    *)
      echo "Unknown option: $1"
      show_help
      exit 1
      ;;
  esac
  shift
done

echo "Optimization complete. Some changes require reboot."

