# Edit /etc/default/grub, remove amdgpu.ppfeaturemask=0xfff7ffff, then:

´´´sh
sudo grub-mkconfig -o /boot/grub/grub.cfg
´´´
# B. Undo cpupower service + governor
´´´bash
sudo systemctl disable --now cpupower.service || true
sudo cpupower frequency-set -g schedutil || true   # or powersave
´´´
# C. Undo ZRAM

´´´bash
sudo systemctl disable --now systemd-zram-setup@zram0.service || true
sudo rm -f /etc/systemd/zram-generator.conf
sudo systemctl daemon-reload
´´´

# D. Remove NVMe udev rule
´´´bash
sudo rm -f /etc/udev/rules.d/60-nvme-scheduler.rules
sudo udevadm control --reload-rules
sudo udevadm trigger
´´´

# E. Remove sysctl tweaks
´´´bash
sudo rm -f /etc/sysctl.d/99-performance-tweaks.conf
sudo sysctl --system
´´´
