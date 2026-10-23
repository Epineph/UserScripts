#!/usr/bin/env bash
# Create and manage persistent QEMU/KVM guests on Arch Linux.
set -Eeuo pipefail
export LC_ALL=C
umask 077

# ---------------------------------------------------------------------------
# Defaults and command-line help
# ---------------------------------------------------------------------------

VM_URI='qemu:///system'
ACTION=''
EXECUTE=0
WITH_SETUP=0
WITH_MANAGER=0
NAME=''
ISO=''
DRIVER_ISO=''
GUEST='linux'
MEMORY=''
MEMORY_MAX=''
VCPUS=''
DISK_SIZE=''
STORAGE_DIR='/var/lib/libvirt/images'
OS_VARIANT=''
CPU='host-passthrough'
CPU_SHARES=''
CPU_LIMIT=''
NETWORK='default'
DISK_BUS=''
NIC_MODEL=''
GRAPHICS='spice'
SECURE_BOOT=''
TPM=''
BOOT_FROM=''
NO_START=0
AUTOSTART=0
VM_DIR=''
DISK_PATH=''
MEDIA_PATH=''
DRIVER_PATH=''
FIRMWARE_CODE=''
FIRMWARE_VARS=''
TEMP_DIR=''
CREATION_BEGUN=0
ROOT=()
VIRSH=()
INSTALL_ARGS=()
CREATE_OPTIONS=()

function usage() {
  cat <<'EOF'
qemu-vm.sh - Arch Linux QEMU/KVM setup and persistent VM creation

Usage:
  qemu-vm.sh setup [--with-manager] [--execute]
  qemu-vm.sh create --name NAME [options] [--execute]
  qemu-vm.sh start --name NAME [--execute]
  qemu-vm.sh eject-iso --name NAME [--execute]
  qemu-vm.sh info --name NAME

Changes are PREVIEWED by default. Add --execute to apply them.
info reads libvirt state and may request sudo authentication.

Host setup:
  --setup                  Run host setup before creating the guest
  --with-manager           Also install virt-manager during setup
                           Setup runs pacman -Syu --needed (full upgrade).

Guest creation:
  --name NAME              Unique VM name, starting with a letter (max 64)
  --iso PATH               Local bootable installation ISO (optional)
  --driver-iso PATH        Optional second ISO, e.g. Windows VirtIO drivers
  --guest linux|windows    Defaults: linux / Windows 11-oriented settings
  --os-variant ID          libosinfo ID (default: generic / win11)
  --memory MIB             Startup RAM (default: 4096 / 8192)
  --memory-max MIB         Balloon ceiling (default: same as --memory)
  --vcpus N                vCPUs (default: 2 / 4), one socket, N cores
  --disk-size GIB          New sparse qcow2 capacity (default: 64 / 128)
  --storage-dir DIR        Parent for a NEW NAME/ directory
                           Default: /var/lib/libvirt/images
  --disk-bus virtio|sata   Default: virtio / sata
  --nic-model virtio|e1000e Default: virtio / e1000e
  --cpu MODEL              host-passthrough or host-model
  --cpu-shares N           Relative CPU weight: 1..10000 on cgroups v2
                           (2..262144 on cgroups v1)
  --cpu-limit PERCENT      Aggregate budget: PERCENT of N vCPUs, 1..100
  --network NAME           Existing active libvirt network (default: default)
  --network bridge=BRIDGE  Existing host bridge (no host reconfiguration)
  --network none           Omit the network interface
  --graphics spice|vnc|none Default: spice; graphical listeners use localhost
  --secure-boot off|on     Default: off / on
                           on enrolls Microsoft certificates in guest NVRAM
  --tpm | --no-tpm         TPM 2.0 emulator (default: off / on)
  --boot iso|disk          Default: iso when --iso is given, otherwise disk
  --no-start               Define the VM but leave it powered off
  --autostart              Start this VM automatically at host boot

General:
  --execute                Apply the displayed operation
  --dry-run                Explicit preview mode; cannot combine with --execute
  -h, --help               Show this help

Examples:
  ./qemu-vm.sh setup --with-manager
  ./qemu-vm.sh setup --with-manager --execute
  ./qemu-vm.sh create --name ArchLab --iso ~/Downloads/archlinux.iso \
    --os-variant archlinux --memory 4096 --vcpus 4 --disk-size 80
  ./qemu-vm.sh create --name Windows11 --guest windows \
    --iso /path/Windows11.iso --no-start --execute
  ./qemu-vm.sh eject-iso --name ArchLab --execute
  ./qemu-vm.sh start --name ArchLab --execute
  ./qemu-vm.sh info --name ArchLab

No existing VM or disk is reconfigured or overwritten by create.
eject-iso requires a powered-off VM and ejects its first CD-ROM only.
Guest OS installation remains interactive in virt-viewer or virt-manager.
EOF
}

# ---------------------------------------------------------------------------
# Errors, command printing, and privilege boundaries
# ---------------------------------------------------------------------------

function die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

function step() {
  printf '\n==> %s\n' "$*"
}

function print_command() {
  printf '  '
  printf '%q ' "$@"
  printf '\n'
}

function cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
}

function on_error() {
  local status=$1 line=$2
  printf '\nOperation failed at script line %s (exit %s).\n' \
    "$line" "$status" >&2
  if ((CREATION_BEGUN)); then
    printf 'Partial VM state was preserved. Inspect: %s\n' "$VM_DIR" >&2
    printf 'Check: sudo virsh --connect %s dominfo %s\n' \
      "$VM_URI" "$NAME" >&2
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'on_error "$?" "$LINENO"' ERR

function require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    die "Missing command '$1'. Run: $0 setup --execute"
}

function init_privileges() {
  if ((EUID != 0)); then
    require_command sudo
    ROOT=(sudo --)
  fi
  VIRSH=("${ROOT[@]}" virsh --connect "$VM_URI")
}

function mutate() {
  print_command "${ROOT[@]}" "$@"
  if ((EXECUTE)); then
    "${ROOT[@]}" "$@"
  fi
}

# ---------------------------------------------------------------------------
# Parse and validate before invoking privileged commands
# ---------------------------------------------------------------------------

function need_value() {
  (($# >= 2)) && [[ -n "$2" && "$2" != --* ]] ||
    die "Option $1 requires a value. See --help."
}

function integer_range() {
  local label=$1 value=$2 minimum=$3 maximum=$4
  [[ "$value" =~ ^[1-9][0-9]{0,8}$ ]] ||
    die "$label must be a positive integer."
  ((value >= minimum && value <= maximum)) ||
    die "$label must be between $minimum and $maximum."
}

function clean_path() {
  # virt-install uses commas as delimiters inside --disk and --boot values.
  [[ "$1" != *','* && ! "$1" =~ [[:cntrl:]] ]] ||
    die 'Paths must not contain commas or control characters.'
}

function resolve_iso() {
  local value=$1 resolved=''
  clean_path "$value"
  [[ -f "$value" && -r "$value" && -s "$value" ]] ||
    die "ISO must be a readable, nonempty regular file: $value"
  [[ "${value,,}" == *.iso ]] || die "ISO path must end in .iso: $value"
  resolved=$(realpath -e -- "$value")
  clean_path "$resolved"
  printf '%s\n' "$resolved"
}

function parse_args() {
  local explicit_preview=0 option=''
  if (($# == 0)); then
    usage
    exit 0
  fi
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    setup | create | start | info | eject-iso)
      ACTION=$1
      shift
      ;;
    *) die "Unknown command: $1. See --help." ;;
  esac
  while (($#)); do
    option=$1
    case "$option" in
      -h | --help)
        usage
        exit 0
        ;;
      --execute)
        EXECUTE=1
        shift
        ;;
      --dry-run)
        explicit_preview=1
        shift
        ;;
      --name)
        need_value "$@"
        NAME=$2
        shift 2
        ;;
      --with-manager)
        WITH_MANAGER=1
        shift
        ;;
      --setup)
        WITH_SETUP=1
        CREATE_OPTIONS+=("$option")
        shift
        ;;
      --no-start)
        NO_START=1
        CREATE_OPTIONS+=("$option")
        shift
        ;;
      --autostart)
        AUTOSTART=1
        CREATE_OPTIONS+=("$option")
        shift
        ;;
      --tpm)
        TPM=on
        CREATE_OPTIONS+=("$option")
        shift
        ;;
      --no-tpm)
        TPM=off
        CREATE_OPTIONS+=("$option")
        shift
        ;;
      --iso | --driver-iso | --guest | --os-variant | --memory | \
        --memory-max | --vcpus | --disk-size | --storage-dir | --disk-bus | \
        --nic-model | --cpu | --cpu-shares | --cpu-limit | --network | \
        --graphics | --secure-boot | --boot)
        need_value "$@"
        CREATE_OPTIONS+=("$option")
        case "$option" in
          --iso) ISO=$2 ;;
          --driver-iso) DRIVER_ISO=$2 ;;
          --guest) GUEST=$2 ;;
          --os-variant) OS_VARIANT=$2 ;;
          --memory) MEMORY=$2 ;;
          --memory-max) MEMORY_MAX=$2 ;;
          --vcpus) VCPUS=$2 ;;
          --disk-size) DISK_SIZE=$2 ;;
          --storage-dir) STORAGE_DIR=$2 ;;
          --disk-bus) DISK_BUS=$2 ;;
          --nic-model) NIC_MODEL=$2 ;;
          --cpu) CPU=$2 ;;
          --cpu-shares) CPU_SHARES=$2 ;;
          --cpu-limit) CPU_LIMIT=$2 ;;
          --network) NETWORK=$2 ;;
          --graphics) GRAPHICS=$2 ;;
          --secure-boot) SECURE_BOOT=$2 ;;
          --boot) BOOT_FROM=$2 ;;
        esac
        shift 2
        ;;
      *) die "Unknown option: $option. See --help." ;;
    esac
  done
  ! ((EXECUTE && explicit_preview)) ||
    die '--execute and --dry-run cannot be combined.'
  if [[ "$ACTION" != create && ${#CREATE_OPTIONS[@]} != 0 ]]; then
    die "${CREATE_OPTIONS[0]} is only valid with create."
  fi
  if ((WITH_MANAGER)) && [[ "$ACTION" != setup ]] && ! ((WITH_SETUP)); then
    die '--with-manager requires setup or create --setup.'
  fi
  if [[ "$ACTION" == setup ]]; then
    [[ -z "$NAME" ]] || die 'setup does not accept --name.'
  else
    [[ "$NAME" =~ ^[A-Za-z][A-Za-z0-9_.-]{0,63}$ ]] ||
      die '--name must start with a letter and use 1..64 letters/digits/_.-.'
  fi
}

function check_host() {
  [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] ||
    die 'This script supports x86_64 Linux hosts only.'
  [[ -r /etc/os-release ]] || die 'Cannot identify the host distribution.'
  local host_id=''
  # os-release also defines NAME, so isolate it from the guest's NAME variable.
  host_id=$(
    # shellcheck disable=SC1091
    source /etc/os-release
    printf '%s' "${ID:-}"
  )
  [[ "$host_id" == arch ]] ||
    die 'This dependency setup targets Arch Linux only.'
}

function validate_create() {
  case "$GUEST" in
    linux)
      MEMORY=${MEMORY:-4096}
      VCPUS=${VCPUS:-2}
      DISK_SIZE=${DISK_SIZE:-64}
      OS_VARIANT=${OS_VARIANT:-generic}
      DISK_BUS=${DISK_BUS:-virtio}
      NIC_MODEL=${NIC_MODEL:-virtio}
      SECURE_BOOT=${SECURE_BOOT:-off}
      TPM=${TPM:-off}
      ;;
    windows)
      MEMORY=${MEMORY:-8192}
      VCPUS=${VCPUS:-4}
      DISK_SIZE=${DISK_SIZE:-128}
      OS_VARIANT=${OS_VARIANT:-win11}
      DISK_BUS=${DISK_BUS:-sata}
      NIC_MODEL=${NIC_MODEL:-e1000e}
      SECURE_BOOT=${SECURE_BOOT:-on}
      TPM=${TPM:-on}
      ;;
    *) die '--guest must be linux or windows.' ;;
  esac
  MEMORY_MAX=${MEMORY_MAX:-$MEMORY}
  integer_range --memory "$MEMORY" 512 1048576
  integer_range --memory-max "$MEMORY_MAX" "$MEMORY" 1048576
  integer_range --vcpus "$VCPUS" 1 1024
  integer_range --disk-size "$DISK_SIZE" 1 65536
  if [[ -n "$CPU_SHARES" ]]; then
    if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
      integer_range --cpu-shares "$CPU_SHARES" 1 10000
    else
      integer_range --cpu-shares "$CPU_SHARES" 2 262144
    fi
  fi
  [[ -z "$CPU_LIMIT" ]] || integer_range --cpu-limit "$CPU_LIMIT" 1 100
  [[ "$OS_VARIANT" =~ ^[A-Za-z0-9_.-]+$ ]] || die 'Invalid OS variant ID.'
  case "$CPU" in
    host-passthrough | host-model) ;;
    *) die '--cpu must be host-passthrough or host-model.' ;;
  esac
  case "$SECURE_BOOT" in on | off) ;; *) die 'Invalid --secure-boot.' ;; esac
  case "$DISK_BUS" in virtio | sata) ;; *) die 'Invalid --disk-bus.' ;; esac
  case "$NIC_MODEL" in virtio | e1000e) ;; *) die 'Invalid --nic-model.' ;; esac
  case "$GRAPHICS" in spice | vnc | none) ;; *) die 'Invalid --graphics.' ;; esac
  [[ "$NETWORK" =~ ^(bridge=)?[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] ||
    die '--network must be a network name, bridge=NAME, or none.'
  if [[ "$NETWORK" == bridge=* ]]; then
    [[ -d "/sys/class/net/${NETWORK#bridge=}/bridge" ]] ||
      die "Host bridge does not exist: ${NETWORK#bridge=}"
  fi
  clean_path "$STORAGE_DIR"
  [[ "$STORAGE_DIR" == /* ]] || die '--storage-dir must be absolute.'
  STORAGE_DIR=$(realpath -m -- "$STORAGE_DIR")
  clean_path "$STORAGE_DIR"
  [[ "$STORAGE_DIR" != / ]] || die 'Use a dedicated storage parent directory.'
  VM_DIR="$STORAGE_DIR/$NAME"
  DISK_PATH="$VM_DIR/disk.qcow2"
  if [[ -n "$ISO" ]]; then
    ISO=$(resolve_iso "$ISO")
    MEDIA_PATH="$VM_DIR/install.iso"
    BOOT_FROM=${BOOT_FROM:-iso}
  else
    BOOT_FROM=${BOOT_FROM:-disk}
  fi
  if [[ -n "$DRIVER_ISO" ]]; then
    DRIVER_ISO=$(resolve_iso "$DRIVER_ISO")
    DRIVER_PATH="$VM_DIR/drivers.iso"
  fi
  case "$BOOT_FROM" in
    iso) [[ -n "$ISO" ]] || die '--boot iso requires --iso.' ;;
    disk) ;;
    *) die '--boot must be iso or disk.' ;;
  esac
  [[ ! -e "$VM_DIR" && ! -L "$VM_DIR" ]] ||
    die "VM storage already exists; nothing overwritten: $VM_DIR"
}

# ---------------------------------------------------------------------------
# Host setup: packages, daemon sockets, default NAT network, KVM
# ---------------------------------------------------------------------------

function detect_daemon_mode() {
  local query='' modular=0 monolithic=0
  # Running daemons take precedence over units merely enabled for the next boot.
  for query in is-active is-enabled; do
    modular=0
    monolithic=0
    if systemctl "$query" --quiet virtqemud.socket 2>/dev/null ||
      systemctl "$query" --quiet virtqemud.service 2>/dev/null; then
      modular=1
    fi
    if systemctl "$query" --quiet libvirtd.socket 2>/dev/null ||
      systemctl "$query" --quiet libvirtd.service 2>/dev/null; then
      monolithic=1
    fi
    ! ((modular && monolithic)) ||
      die "Both libvirt daemon modes are $query; resolve that conflict first."
    if ((modular)); then
      printf 'modular\n'
      return
    fi
    if ((monolithic)); then
      printf 'monolithic\n'
      return
    fi
  done
  printf 'modular\n'
}

function setup_host() {
  local packages=(qemu-desktop libvirt virt-install virt-viewer edk2-ovmf
    virt-firmware swtpm dnsmasq nftables)
  local units=() network_names='' active_names='' default_xml='' mode=''
  ((WITH_MANAGER == 0)) || packages+=(virt-manager)
  step 'Install dependencies; --needed skips reinstalling current packages'
  mutate pacman -Syu --needed -- "${packages[@]}"

  if ((! EXECUTE)); then
    printf '\n  Detect the existing libvirt mode. Fresh hosts use modular\n'
    printf '  services and sockets for QEMU, networking and storage, with\n'
    printf '  auxiliary sockets for secrets, logging and locks.\n'
    printf '  Preserve monolithic libvirtd on hosts already using it.\n'
    printf '  Define the packaged default NAT network only if it is absent;\n'
    printf '  start it and enable its autostart. Load kvm_intel or kvm_amd.\n'
    return
  fi
  require_command virsh
  require_command systemctl
  step 'Enable the libvirt daemon mode already configured on this host'
  mode=$(detect_daemon_mode)
  if [[ "$mode" == modular ]]; then
    units=(virtqemud.service virtnetworkd.service virtstoraged.service
      virtqemud.socket virtnetworkd.socket virtstoraged.socket
      virtnodedevd.socket virtnwfilterd.socket virtsecretd.socket
      virtlogd.socket virtlockd.socket)
  else
    units=(libvirtd.service libvirtd.socket virtlogd.socket virtlockd.socket)
  fi
  mutate systemctl enable --now "${units[@]}"
  "${VIRSH[@]}" list --all >/dev/null

  step 'Enable the default NAT network without replacing its configuration'
  network_names=$("${VIRSH[@]}" net-list --all --name)
  if ! contains_line "$network_names" default; then
    for default_xml in /usr/share/libvirt/networks/default.xml \
      /etc/libvirt/qemu/networks/default.xml; do
      [[ ! -f "$default_xml" ]] || break
    done
    [[ -f "$default_xml" ]] || die 'Packaged default network XML is missing.'
    mutate virsh --connect "$VM_URI" net-define "$default_xml" --validate
  fi
  active_names=$("${VIRSH[@]}" net-list --name)
  if ! contains_line "$active_names" default; then
    mutate virsh --connect "$VM_URI" net-start default
  fi
  mutate virsh --connect "$VM_URI" net-autostart default
  ensure_kvm
}

function contains_line() {
  local content=$1 wanted=$2 line=''
  while IFS= read -r line; do
    [[ "$line" != "$wanted" ]] || return 0
  done <<<"$content"
  return 1
}

function ensure_kvm() {
  local cpu_info=''
  if [[ ! -c /dev/kvm ]]; then
    cpu_info=$(</proc/cpuinfo)
    if [[ "$cpu_info" == *AuthenticAMD* ]]; then
      mutate modprobe kvm_amd
    elif [[ "$cpu_info" == *GenuineIntel* ]]; then
      mutate modprobe kvm_intel
    else
      die 'Cannot identify an Intel or AMD virtualization module.'
    fi
  fi
  [[ -c /dev/kvm ]] ||
    die 'No /dev/kvm. Enable AMD-V/VT-x in firmware and check kernel modules.'
}

# ---------------------------------------------------------------------------
# Domain generation: firmware metadata, argument arrays, XML verification
# ---------------------------------------------------------------------------

function discover_secure_firmware() {
  local firmware_result=''
  # Read the installed descriptors instead of hard-coding OVMF package paths.
  firmware_result=$(
    python3 - <<'PY'
import json
from pathlib import Path

for descriptor in sorted(Path('/usr/share/qemu/firmware').glob('*.json')):
  info = json.loads(descriptor.read_text())
  if 'secure-boot' not in info.get('features', []):
    continue
  targets = info.get('targets', [])
  if not any(t.get('architecture') == 'x86_64' and
             any('q35' in m for m in t.get('machines', [])) for t in targets):
    continue
  mapping = info.get('mapping', {})
  if mapping.get('device') != 'flash':
    continue
  code = mapping.get('executable', {})
  variables = mapping.get('nvram-template', {})
  if code.get('format') != 'raw' or variables.get('format') != 'raw':
    continue
  paths = [code.get('filename', ''), variables.get('filename', '')]
  if all(Path(p).is_file() for p in paths):
    print('\n'.join(paths))
    break
else:
  raise SystemExit('No x86_64 q35 Secure Boot firmware descriptor found.')
PY
  )
  FIRMWARE_CODE=${firmware_result%%$'\n'*}
  FIRMWARE_VARS=${firmware_result#*$'\n'}
  clean_path "$FIRMWARE_CODE"
  clean_path "$FIRMWARE_VARS"
}

function build_install_args() {
  local boot='' network='' memory="$MEMORY" balloon=none tuning=''
  local disk_options='' media_options='' driver_options=''
  if [[ "$BOOT_FROM" == iso ]]; then boot='cdrom,hd'; else boot='hd,cdrom'; fi
  if [[ "$SECURE_BOOT" == on ]]; then
    boot+=",loader=$(suboption_path "$FIRMWARE_CODE")"
    boot+=',loader.readonly=yes,loader.type=pflash,loader.secure=yes'
    boot+=",nvram.template=$(suboption_path "$VM_DIR/secure-vars-template.fd")"
  else
    boot+=',uefi,firmware.feature0.name=secure-boot'
    boot+=',firmware.feature0.enabled=no'
  fi
  boot+=',bootmenu.enable=yes'
  if ((MEMORY_MAX > MEMORY)); then
    memory+=",maxmemory=$MEMORY_MAX"
    balloon=virtio
  fi
  case "$NETWORK" in
    none) network=none ;;
    bridge=*) network="$NETWORK,model=$NIC_MODEL" ;;
    *) network="network=$NETWORK,model=$NIC_MODEL" ;;
  esac
  disk_options="path=$(suboption_path "$DISK_PATH"),size=$DISK_SIZE"
  disk_options+=",format=qcow2,bus=$DISK_BUS"
  media_options="path=$(suboption_path "$MEDIA_PATH")"
  media_options+=',device=cdrom,bus=sata,readonly=on'
  driver_options="path=$(suboption_path "$DRIVER_PATH")"
  driver_options+=',device=cdrom,bus=sata,readonly=on'
  INSTALL_ARGS=(virt-install --connect "$VM_URI" --name "$NAME"
    --virt-type kvm --arch x86_64 --machine q35 --cpu "$CPU"
    --memory "$memory" --vcpus "$VCPUS,sockets=1,cores=$VCPUS,threads=1"
    --osinfo "$OS_VARIANT" --import --boot "$boot"
    --disk "$disk_options"
    --network "$network" --memballoon "$balloon"
    --rng /dev/urandom --noautoconsole --print-xml --dry-run)
  [[ -z "$MEDIA_PATH" ]] || INSTALL_ARGS+=(--disk "$media_options")
  [[ -z "$DRIVER_PATH" ]] || INSTALL_ARGS+=(--disk "$driver_options")
  if [[ "$GRAPHICS" == none ]]; then
    INSTALL_ARGS+=(--graphics none --console 'pty,target_type=serial')
  else
    INSTALL_ARGS+=(--graphics "$GRAPHICS,listen=127.0.0.1" --video vga)
  fi
  if [[ "$TPM" == on ]]; then
    INSTALL_ARGS+=(--tpm
      'backend.type=emulator,backend.version=2.0,model=tpm-crb')
  else
    INSTALL_ARGS+=(--tpm none)
  fi
  [[ "$SECURE_BOOT" != on ]] || INSTALL_ARGS+=(--features smm=on)
  if [[ -n "$CPU_SHARES" ]]; then tuning="shares=$CPU_SHARES"; fi
  if [[ -n "$CPU_LIMIT" ]]; then
    [[ -z "$tuning" ]] || tuning+=','
    tuning+="global_period=100000,global_quota=$((VCPUS * CPU_LIMIT * 1000))"
  fi
  [[ -z "$tuning" ]] || INSTALL_ARGS+=(--cputune "$tuning")
}

function suboption_path() {
  # virt-install parses its comma-delimited values with POSIX shlex too.
  # Preserve quotes and backslashes at that second parsing layer.
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '"%s"' "$value"
}

function ensure_storage_parent() {
  if ((! EXECUTE)) || ! "${ROOT[@]}" test -d "$STORAGE_DIR"; then
    # install -d creates missing ancestors with 0755 despite our private umask.
    # Skip existing storage roots so their permissions remain unchanged.
    mutate install -d -m 0755 -- "$STORAGE_DIR"
  fi
}

function check_storage_traversal() {
  # Require directory traversal without weakening private home directories.
  # An ACL-only grant cannot be inferred portably here; use a shared VM root.
  "${ROOT[@]}" python3 - "$STORAGE_DIR" <<'PY'
import stat
import sys
from pathlib import Path

directory = Path(sys.argv[1])
for parent in [directory, *directory.parents]:
  if parent.exists():
    if not parent.is_dir() or not parent.stat().st_mode & stat.S_IXOTH:
      raise SystemExit('Storage ancestor is not traversable by QEMU: ' +
                       str(parent) + '\nUse /var/lib/libvirt/images or a ' +
                       'shared directory with traversable ancestors.')
PY
}

function check_connection() {
  require_command virsh
  "${VIRSH[@]}" list --all >/dev/null ||
    die 'Cannot connect to system libvirt. Run setup --execute first.'
}

function verify_definition() {
  local xml_path=$1
  python3 - "$xml_path" "$NAME" "$DISK_PATH" "$MEDIA_PATH" \
    "$DRIVER_PATH" "$SECURE_BOOT" "$TPM" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

filename, name, disk, iso, drivers, secure, tpm = sys.argv[1:]
root = ET.parse(filename).getroot()
def check(condition, message):
  if not condition:
    raise SystemExit('Domain verification failed: ' + message)

check(root.findtext('name') == name, 'unexpected guest name')
check(root.findtext('uuid'), 'missing unique guest UUID')
check(root.get('type') == 'kvm', 'guest is not configured for KVM')
sources = [(d.get('device'), d.find('source').get('file'))
           for d in root.findall('devices/disk')
           if d.find('source') is not None]
check(('disk', disk) in sources, 'wrong primary disk')
for media in (iso, drivers):
  check(not media or ('cdrom', media) in sources, 'requested ISO is absent')
if secure == 'on':
  loader = root.find('os/loader')
  check(loader is not None and loader.get('secure') == 'yes',
        'Secure Boot loader is not enabled')
  nvram = root.find('os/nvram')
  check(nvram is not None and nvram.get('template') ==
        str(Path(disk).parent / 'secure-vars-template.fd'),
        'wrong Secure Boot NVRAM template')
else:
  guest_os = root.find('os')
  check(guest_os is not None and guest_os.get('firmware') == 'efi',
        'UEFI firmware selection is missing')
  disabled = guest_os.find("firmware/feature[@name='secure-boot']")
  check(disabled is not None and disabled.get('enabled') == 'no',
        'Secure Boot was not explicitly disabled')
backend = root.find('devices/tpm/backend')
check((backend is not None) == (tpm == 'on'), 'unexpected TPM state')
if tpm == 'on':
  check(backend.get('type') == 'emulator' and backend.get('version') == '2.0',
        'TPM is not a TPM 2.0 emulator')
print('Verified guest name, KVM, disk, ISO media, firmware and TPM definition.')
PY
}

function create_vm() {
  local names='' networks='' defined_xml=''
  step "Plan for $NAME"
  printf '  RAM: %s MiB; ceiling: %s MiB; vCPUs: %s; disk: %s GiB\n' \
    "$MEMORY" "$MEMORY_MAX" "$VCPUS" "$DISK_SIZE"
  printf '  UEFI; Secure Boot: %s; TPM 2.0: %s; network: %s\n' \
    "$SECURE_BOOT" "$TPM" "$NETWORK"
  printf '  Storage: %s\n' "$VM_DIR"

  if ((! EXECUTE)); then
    if [[ "$SECURE_BOOT" == on ]]; then
      if command -v python3 >/dev/null &&
        [[ -d /usr/share/qemu/firmware ]]; then
        discover_secure_firmware
      else
        FIRMWARE_CODE='<discovered-secure-OVMF-code>'
        FIRMWARE_VARS='<discovered-OVMF-vars-template>'
      fi
    fi
    printf '\n  Check KVM, libvirt, firmware, network and unique name.\n'
    ensure_storage_parent
    print_command "${ROOT[@]}" mkdir -m 0755 -- "$VM_DIR"
    preview_storage
    build_install_args
    print_command "${ROOT[@]}" "${INSTALL_ARGS[@]}"
    printf '  Verify the XML; register it with virsh define --validate.\n'
    ((AUTOSTART == 0)) || print_command "${VIRSH[@]}" autostart "$NAME"
    ((NO_START)) || print_command "${VIRSH[@]}" start "$NAME"
    print_viewer
    return
  fi

  require_command virt-install
  require_command qemu-img
  require_command python3
  [[ "$SECURE_BOOT" != on ]] || require_command virt-fw-vars
  check_connection
  ensure_kvm
  names=$("${VIRSH[@]}" list --all --name)
  ! contains_line "$names" "$NAME" || die "VM already exists: $NAME"
  if [[ "$NETWORK" != none && "$NETWORK" != bridge=* ]]; then
    networks=$("${VIRSH[@]}" net-list --name)
    contains_line "$networks" "$NETWORK" ||
      die "Network '$NETWORK' is absent or inactive. Start it with virsh."
  fi
  if [[ "$SECURE_BOOT" == on ]]; then discover_secure_firmware; fi
  check_storage_traversal
  # Test as root too: a protected parent must never hide an existing directory.
  if "${ROOT[@]}" test -e "$VM_DIR" || "${ROOT[@]}" test -L "$VM_DIR"; then
    die "VM storage already exists: $VM_DIR"
  fi
  ensure_storage_parent
  # mkdir without -p atomically refuses collisions, even between script instances.
  mutate mkdir -m 0755 -- "$VM_DIR"
  CREATION_BEGUN=1
  prepare_storage
  build_install_args
  TEMP_DIR=$(mktemp -d -t qemu-vm.XXXXXXXX)
  step 'Generate and validate the persistent domain definition'
  print_command "${ROOT[@]}" "${INSTALL_ARGS[@]}"
  "${ROOT[@]}" "${INSTALL_ARGS[@]}" >"$TEMP_DIR/domain.xml"
  verify_definition "$TEMP_DIR/domain.xml"
  mutate install -m 0600 -- "$TEMP_DIR/domain.xml" "$VM_DIR/domain.xml"
  # virt-install supplies a fresh UUID; libvirt rejects a racing same-name guest
  # with a different UUID instead of replacing its definition.
  mutate virsh --connect "$VM_URI" define "$VM_DIR/domain.xml" --validate
  defined_xml="$TEMP_DIR/defined.xml"
  "${VIRSH[@]}" dumpxml "$NAME" --inactive >"$defined_xml"
  verify_definition "$defined_xml"
  ((AUTOSTART == 0)) || mutate virsh --connect "$VM_URI" autostart "$NAME"
  if ((! NO_START)); then mutate virsh --connect "$VM_URI" start "$NAME"; fi
  CREATION_BEGUN=0
  show_info
  print_viewer
}

function preview_storage() {
  if [[ -n "$ISO" ]]; then
    print_command "${ROOT[@]}" cp --reflink=auto --sparse=always --no-clobber \
      -- "$ISO" "$MEDIA_PATH"
  fi
  if [[ -n "$DRIVER_ISO" ]]; then
    print_command "${ROOT[@]}" cp --reflink=auto --sparse=always --no-clobber \
      -- "$DRIVER_ISO" "$DRIVER_PATH"
  fi
  if [[ "$SECURE_BOOT" == on ]]; then
    print_command "${ROOT[@]}" virt-fw-vars --input "$FIRMWARE_VARS" \
      --output "$VM_DIR/secure-vars-template.fd" --enroll-microsoft \
      --microsoft-db all --microsoft-kek all --secure-boot
  fi
  print_command "${ROOT[@]}" qemu-img create -f qcow2 \
    -o preallocation=off "$DISK_PATH" "${DISK_SIZE}G"
}

function prepare_storage() {
  step 'Stage media and create a new sparse qcow2 disk'
  if [[ -n "$ISO" ]]; then
    mutate cp --reflink=auto --sparse=always --no-clobber -- "$ISO" "$MEDIA_PATH"
    mutate chmod 0644 -- "$MEDIA_PATH"
    "${ROOT[@]}" cmp -s -- "$ISO" "$MEDIA_PATH" ||
      die "Staged installation ISO differs from the source. Inspect $VM_DIR"
  fi
  if [[ -n "$DRIVER_ISO" ]]; then
    mutate cp --reflink=auto --sparse=always --no-clobber \
      -- "$DRIVER_ISO" "$DRIVER_PATH"
    mutate chmod 0644 -- "$DRIVER_PATH"
    "${ROOT[@]}" cmp -s -- "$DRIVER_ISO" "$DRIVER_PATH" ||
      die "Staged driver ISO differs from the source. Inspect $VM_DIR"
  fi
  if [[ "$SECURE_BOOT" == on ]]; then
    step 'Enroll guest Secure Boot certificates in a private NVRAM template'
    mutate virt-fw-vars --input "$FIRMWARE_VARS" \
      --output "$VM_DIR/secure-vars-template.fd" --enroll-microsoft \
      --microsoft-db all --microsoft-kek all --secure-boot
    mutate chmod 0644 -- "$VM_DIR/secure-vars-template.fd"
  fi
  mutate qemu-img create -f qcow2 -o preallocation=off \
    "$DISK_PATH" "${DISK_SIZE}G"
  # libvirt's dynamic ownership grants its QEMU user access when the guest starts.
  mutate chmod 0600 -- "$DISK_PATH"
}

# ---------------------------------------------------------------------------
# Existing VM operations and final state
# ---------------------------------------------------------------------------

function show_info() {
  step "Current libvirt state: $NAME"
  "${VIRSH[@]}" dominfo "$NAME"
  "${VIRSH[@]}" domblklist "$NAME" --details
  "${VIRSH[@]}" domiflist "$NAME"
}

function print_viewer() {
  if [[ "$GRAPHICS" == none ]]; then
    printf '\nSerial console (requires guest serial-console configuration):\n'
    print_command "${VIRSH[@]}" console "$NAME"
  else
    printf '\nOpen the graphical console from your desktop user account:\n'
    print_command virt-viewer --connect "$VM_URI" "$NAME"
  fi
}

function eject_iso() {
  local state='' target=''
  if ((! EXECUTE)); then
    printf 'Check that %s is powered off, then eject its first CD-ROM.\n' "$NAME"
    printf 'The ISO file and any second driver CD-ROM remain in place.\n'
    return
  fi
  require_command python3
  check_connection
  state=$("${VIRSH[@]}" domstate "$NAME")
  [[ "$state" == 'shut off' ]] ||
    die 'eject-iso requires a powered-off VM. Shut down the guest first.'
  target=$("${VIRSH[@]}" dumpxml "$NAME" --inactive | python3 -c '
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.stdin).getroot()
disks = root.findall("devices/disk[@device=\"cdrom\"]")
if not disks:
  raise SystemExit("No CD-ROM device found.")
print(disks[0].find("target").get("dev"))
')
  mutate virsh --connect "$VM_URI" change-media "$NAME" "$target" \
    --eject --config
  show_info
}

function main() {
  parse_args "$@"
  check_host
  [[ "$ACTION" != create ]] || validate_create
  init_privileges
  if ((! EXECUTE)) && [[ "$ACTION" != info ]]; then
    printf 'PREVIEW ONLY. Add --execute to apply this plan.\n'
  fi
  case "$ACTION" in
    setup) setup_host ;;
    create)
      ((WITH_SETUP == 0)) || setup_host
      create_vm
      ;;
    start)
      if ((EXECUTE)); then check_connection; fi
      mutate virsh --connect "$VM_URI" start "$NAME"
      ;;
    info)
      check_connection
      show_info
      ;;
    eject-iso) eject_iso ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
