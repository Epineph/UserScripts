#!/usr/bin/env bash
set -euo pipefail
HELP=$(cat <<'EOF'
vm-new-iso — Create a VM from an installer ISO.

USAGE:
  vm-new-iso --name NAME --iso /path/file.iso [--disk 40G] [--vcpus 4] [--ram 4096]
             [--net default|bridge=br0] [--os-variant archlinux|debian12|...]
             [--uefi-secureboot]

Console on serial (graphics=none) is enabled.
EOF
)
[[ "${1:-}" =~ ^(-h|--help)$ ]] && { echo "$HELP"; exit 0; }

NAME=""; ISO=""; DISK="40G"; VCPUS=2; RAM=2048; NET="network=default"; OSVARIANT="generic"; UEFI_SB=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2;;
    --iso) ISO="$2"; shift 2;;
    --disk) DISK="$2"; shift 2;;
    --vcpus) VCPUS="$2"; shift 2;;
    --ram) RAM="$2"; shift 2;;
    --net) NET="$2"; shift 2;;
    --os-variant) OSVARIANT="$2"; shift 2;;
    --uefi-secureboot) UEFI_SB=1; shift;;
    *) echo "Unknown arg: $1"; exit 2;;
  esac
done

[[ -n "$NAME" && -n "$ISO" ]] || { echo "Require --name and --iso"; exit 1; }
[[ -r "$ISO" ]] || { echo "ISO not readable: $ISO"; exit 1; }

IMG="/var/lib/libvirt/images/${NAME}.qcow2"
qemu-img create -f qcow2 "$IMG" "$DISK"

if [[ $UEFI_SB -eq 1 ]]; then
  LOADER="/usr/share/edk2-ovmf/x64/OVMF_CODE.secboot.fd"
  NVRAM_TEMPLATE="/usr/share/edk2-ovmf/x64/OVMF_VARS.secboot.fd"
else
  LOADER="/usr/share/edk2-ovmf/x64/OVMF_CODE.fd"
  NVRAM_TEMPLATE="/usr/share/edk2-ovmf/x64/OVMF_VARS.fd"
fi

virt-install \
  --name "$NAME" \
  --memory "$RAM" --vcpus "$VCPUS" \
  --cpu host-passthrough \
  --os-variant "$OSVARIANT" \
  --cdrom "$ISO" \
  --disk path="$IMG",bus=virtio,format=qcow2,cache=none,discard=unmap \
  --network "$NET",model=virtio \
  --graphics none \
  --console pty,target_type=serial \
  --boot loader="$LOADER",loader.readonly=yes,loader.type=pflash,nvram.template="$NVRAM_TEMPLATE" \
  --tpm backend.type=emulator,backend.version=2.0,model=tpm-crb \
  --extra-args 'console=ttyS0,115200n8 serial'

echo "VM '$NAME' started. Use: virsh console $NAME"
