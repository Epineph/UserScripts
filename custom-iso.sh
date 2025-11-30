#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
USER_DIR="$HOME"
ISO_NAME="custom-arch-iso"
ISO_ROOT="${USER_DIR}/ISOBUILD"
ISO_HOME="${ISO_ROOT}/${ISO_NAME}"
AIROOTFS="${ISO_HOME}/airootfs"
WORK_DIR="${ISO_HOME}/WORK"
OUT_DIR="${ISO_HOME}/ISOOUT"

EXTRA_ISO_PACKAGES=(fzf lsof strace git gptfdisk bat fd reflector rsync)
HOST_DEP_PACKAGES=(archiso git python fzf lsof strace gptfdisk bat fd
  ddrescue reflector rsync)

# ─────────────────────────────── usage ───────────────────────────────
function usage() {
  cat <<EOF
usage: ${SCRIPT_NAME} [--force] [--burn]

Build a custom Arch ISO based on the stock "releng" profile, with:

  • Extra tools on the live ISO:
      fzf, lsof, strace, git, gptfdisk, bat, fd, reflector, rsync
  • A cleaned-up pacman.conf (official repos, Chaotic-AUR commented)
  • Preconfigured sshd_config, vconsole.conf, locale.conf, locale.gen
  • Template mkinitcpio.conf, /etc/default/grub, /etc/crypttab
  • A .bashrc template stored on the ISO for later copying
  • Helper scripts on the ISO:
      - setup-heini       (create user 'heini', set passwords)
      - new-mirrors       (reflector wrapper for DK/DE/SE/NO)
      - enable-chaotic-aur (post-boot Chaotic-AUR setup)

Behavior:

  • After building, the script will ALWAYS ask whether to burn the ISO
    to a USB device with ddrescue.
  • With --burn, the script will skip the extra yes/no and go directly
    to the interactive device selection + confirmation.

Options:
  --force      Remove any existing \$HOME/ISOBUILD/custom-arch-iso
               before rebuilding
  --burn       After building, immediately offer burning to USB
               without an extra yes/no step (still device-confirmed)
  -h, --help   Show this help and exit
EOF
}

# ───────────────────── host dependency checks ────────────────────────
function ensure_dependencies() {
  echo "==> Checking required host packages..."
  local missing=()
  local pkg
  for pkg in "${HOST_DEP_PACKAGES[@]}"; do
    if ! pacman -Qi "$pkg" &>/dev/null; then
      missing+=("$pkg")
    fi
  done

  if ((${#missing[@]} > 0)); then
    echo "The following packages are missing and will be installed:"
    printf '  %s\n' "${missing[@]}"
    sudo pacman -S --needed "${missing[@]}"
  else
    echo "All required host packages already installed."
  fi
}

# ───────────────────────── profile prep ──────────────────────────────
function prepare_profile() {
  local force="$1"

  if [[ -d "$ISO_HOME" ]]; then
    if [[ "$force" != "true" ]]; then
      echo "ERROR: ${ISO_HOME} already exists."
      echo "Re-run with --force to remove it automatically."
      exit 1
    fi
    echo "==> Removing existing ${ISO_HOME} (force)..."
    rm -rf "$ISO_HOME"
  fi

  mkdir -p "$ISO_ROOT"
  echo "==> Copying releng profile to ${ISO_HOME}..."
  cp -r /usr/share/archiso/configs/releng "$ISO_HOME"
}

# ───────────────────── extra ISO package list ────────────────────────
function append_iso_packages() {
  local pkg_file="${ISO_HOME}/packages.x86_64"
  echo "==> Ensuring extra tools are present in packages.x86_64..."
  local pkg
  for pkg in "${EXTRA_ISO_PACKAGES[@]}"; do
    if ! grep -q -E "^${pkg}(\s|$)" "$pkg_file"; then
      echo "  + ${pkg}"
      echo "$pkg" >>"$pkg_file"
    else
      echo "  = ${pkg} (already listed)"
    fi
  done
}

# ───────────────────────── pacman.conf ───────────────────────────────
function install_pacman_conf() {
  local dst_sys="${ISO_HOME}/pacman.conf"
  local dst_ai="${AIROOTFS}/etc/pacman.conf"

  echo "==> Installing cleaned pacman.conf (official + Chaotic commented)..."
  mkdir -p "$(dirname "$dst_sys")" "$(dirname "$dst_ai")"

  cat >"$dst_sys" <<'EOF'
#
# /etc/pacman.conf  (custom ISO template)
#

[options]
HoldPkg             = pacman glibc
Architecture        = auto
Color
CheckSpace
VerbosePkgLists
ParallelDownloads   = 5
ILoveCandy
SigLevel            = Required DatabaseOptional
LocalFileSigLevel   = Optional

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[multilib]
Include = /etc/pacman.d/mirrorlist

# -----------------------------------------------------------------------------
# Chaotic-AUR (initially DISABLED)
# Enable safely after networking is up by running:
#   enable-chaotic-aur
# This script will:
#   • Initialise / refresh pacman-key + archlinux-keyring
#   • Import + locally sign:
#       FBA220DFC880C036
#       3056513887B78AEB
#   • Install chaotic-keyring + chaotic-mirrorlist
#   • Uncomment / append this repo block:
#
#[chaotic-aur]
#Server = https://geo-mirror.chaotic.cx/$repo/$arch
#Include = /etc/pacman.d/chaotic-mirrorlist
# -----------------------------------------------------------------------------

#[archlinuxcn]
#Server = https://repo.archlinuxcn.org/$arch

#[bioarchlinux]
#Server = https://repo.bioarchlinux.org/$arch

#[chaotic-aur]
#Server = https://geo-mirror.chaotic.cx/$repo/$arch
#Include = /etc/pacman.d/chaotic-mirrorlist

#[dissolve]
#Server = https://dissolve.ru/archrepo/$arch

#[arch4edu]
#Server = https://pkg.fef.moe/arch4edu/$arch
#Server = https://mirrors.tuna.tsinghua.edu.cn/arch4edu/$arch

#[sublime-text]
#Server = https://download.sublimetext.com/arch/stable/$arch

EOF

  mkdir -p "$(dirname "$dst_ai")"
  cp "$dst_sys" "$dst_ai"
}

# ───────────────────────── sshd_config ───────────────────────────────
function install_sshd_config() {
  local dst="${AIROOTFS}/etc/ssh/sshd_config"
  echo "==> Installing sshd_config template..."
  mkdir -p "$(dirname "$dst")"

  cat >"$dst" <<'EOF'
Include /etc/ssh/sshd_config.d/*.conf

Port 22

PubkeyAuthentication yes
AuthorizedKeysFile  .ssh/authorized_keys

PasswordAuthentication yes

AllowAgentForwarding yes
AllowTcpForwarding yes
GatewayPorts yes
X11Forwarding yes
PermitTTY yes
TCPKeepAlive yes
PermitUserEnvironment yes
UseDNS yes
PermitTunnel yes

Subsystem sftp /usr/lib/ssh/sftp-server
EOF
}

# ─────────────────────── vconsole / locale ───────────────────────────
function install_vconsole_conf() {
  local dst="${AIROOTFS}/etc/vconsole.conf"
  echo "==> Installing vconsole.conf..."
  mkdir -p "$(dirname "$dst")"

  cat >"$dst" <<'EOF'
XKBLAYOUT=dk
KEYMAP=dk-latin1
EOF
}

function install_locale_conf() {
  local dst="${AIROOTFS}/etc/locale.conf"
  echo "==> Installing locale.conf..."
  mkdir -p "$(dirname "$dst")"

  cat >"$dst" <<'EOF'
LANG=en_DK.UTF-8
LC_COLLATE=C
LC_TIME=en_DK.UTF-8
LC_NUMERIC=en_DK.UTF-8
LC_MONETARY=en_DK.UTF-8
LC_PAPER=en_DK.UTF-8
LC_MEASUREMENT=en_DK.UTF-8
EOF
}

function install_locale_gen() {
  local dst="${AIROOTFS}/etc/locale.gen"
  echo "==> Installing minimal locale.gen..."
  mkdir -p "$(dirname "$dst")"

  cat >"$dst" <<'EOF'
# Minimal locale.gen for custom ISO
en_DK.UTF-8 UTF-8
EOF
}

# ─────────────────────── mkinitcpio.conf ─────────────────────────────
function install_mkinitcpio_conf() {
  local dst="${AIROOTFS}/etc/mkinitcpio.conf"
  echo "==> Installing mkinitcpio.conf template..."
  mkdir -p "$(dirname "$dst")"

  cat >"$dst" <<'EOF'
# Minimal mkinitcpio.conf template for custom ISO / installed system
#
# Adjust MODULES and HOOKS per-machine after install.

MODULES=()
BINARIES=()
FILES=()

HOOKS=(base udev autodetect modconf block filesystems fsck)
EOF
}

# ───────────────────── /etc/pacman.d/mirrorlist ──────────────────────
function copy_mirrorlist() {
  local src="/etc/pacman.d/mirrorlist"
  local dst="${AIROOTFS}/etc/pacman.d/mirrorlist"
  echo "==> Copying current system mirrorlist to ISO..."
  mkdir -p "$(dirname "$dst")"
  sudo cp "$src" "$dst"
}

# ───────────────────── /etc/default/grub ─────────────────────────────
function install_grub_default() {
  local dst="${AIROOTFS}/etc/default/grub"
  echo "==> Installing /etc/default/grub template..."
  mkdir -p "$(dirname "$dst")"

  cat >"$dst" <<'EOF'
# GRUB boot loader configuration (template for installed system)

GRUB_DEFAULT="saved"
GRUB_TIMEOUT="10"
GRUB_DISTRIBUTOR="Arch"
GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=3 nowatchdog"
GRUB_CMDLINE_LINUX=""

GRUB_PRELOAD_MODULES="part_gpt part_msdos luks cryptodisk lvm ext2"
GRUB_ENABLE_CRYPTODISK=y
GRUB_TIMEOUT_STYLE="menu"
GRUB_TERMINAL_INPUT=console
GRUB_GFXMODE=auto
GRUB_GFXPAYLOAD_LINUX=keep
GRUB_DISABLE_RECOVERY=true
GRUB_DISABLE_OS_PROBER=false
GRUB_SAVEDEFAULT="true"

# Example encrypted root parameters (commented, for reference only):
#GRUB_CMDLINE_LINUX="rd.luks.name=e6504a00-5e0c-46a8-b90b-6a8bd7678edd=cryptroot \
# rd.luks.options=discard rd.lvm.vg=linux root=/dev/linux/root \
# resume=UUID=07ffe579-f3c7-440b-88d9-fbf2b4a4c889 rw"
EOF
}

# ─────────────────────────── sudoers ─────────────────────────────────
function install_sudoers() {
  local dst="${AIROOTFS}/etc/sudoers"
  echo "==> Installing sudoers template (no NOPASSWD for root)..."
  mkdir -p "$(dirname "$dst")"

  cat >"$dst" <<'EOF'
## sudoers file (custom ISO template)

Defaults!/usr/bin/visudo env_keep += "SUDO_EDITOR EDITOR VISUAL"

Defaults secure_path="/home/heini/repos/vcpkg:/home/heini/.cargo/bin:\
/home/heini/bin:/home/heini/bin/bin:/usr/local/sbin:/usr/local/bin:/usr/bin"

# Allow heini passwordless sudo on installed system (if user exists).
heini ALL=(ALL:ALL) NOPASSWD: ALL

root  ALL=(ALL:ALL) ALL
%wheel ALL=(ALL:ALL) ALL

@includedir /etc/sudoers.d

# Use global timestamp for sudo authentication
Defaults timestamp_type=global

# Set sudo authentication timeout to 15 minutes
Defaults timestamp_timeout=15
EOF

  chmod 440 "$dst"
}

# ────────────────────────── crypttab ─────────────────────────────────
function install_crypttab_template() {
  local dst="${AIROOTFS}/etc/crypttab"
  echo "==> Installing crypttab template (commented example)..."
  mkdir -p "$(dirname "$dst")"

  cat >"$dst" <<'EOF'
# Example crypttab entry for an encrypted root (commented, reference only)
#cryptroot UUID=d6bdf062-1bbe-410b-8284-e2d085110b8c none luks,discard
EOF
}

# ─────────────────────── install-bashrc.example ──────────────────────
function install_bashrc_template() {
  local dst_root="${AIROOTFS}/root/install-bashrc.example"
  echo "==> Installing .bashrc template at ${dst_root}..."
  mkdir -p "$(dirname "$dst_root")"

  cat >"$dst_root" <<'EOF'
#
# ~/.bashrc  — install-time helper template
#

[[ $- != *i* ]] && return

alias ls='ls --color=auto'
alias grep='grep --color=auto'
PS1='[\u@\h \W]\$ '

export LANGUAGE=en_DK.UTF-8
export LC_ALL=C.UTF-8
export LOC_BIN=/usr/local/bin
export CARGO_BIN=$HOME/.cargo/bin
export REPOS=$HOME/repos

export PATH=$LOC_BIN:$HOME/.cargo/bin:$HOME/bin:$HOME/bin/bin:$REPOS/vcpkg:$PATH

# Functions below are primarily for use on the installed system
# after copying this file into place as ~/.bashrc.

function chowd() {
  local DIR_NAME=${1:-$LOC_BIN}
  sudo chown -R "$USER":"$USER" "$DIR_NAME"
  sudo chmod -R 777 "$DIR_NAME"
  # shellcheck source=/dev/null
  source "$HOME/.bashrc"
  echo "Changed ownership and permissions for $DIR_NAME"
  echo "Consider running clone_repos function"
}

function clone_repos() {
  if [[ ! -d "$HOME/repos" ]]; then
    sudo mkdir -p "$HOME/repos"
    sudo chmod 777 -R "$HOME/repos"
    sudo chown -R "$USER":"$USER" "$HOME/repos"
  fi
  if [[ ! -d "$HOME/repos/UserScripts" ]]; then
    yes | sudo pacman -Syy --needed reflector rsync git
    sudo git -C "$REPOS" clone https://github.com/Epineph/UserScripts
    sudo git -C "$REPOS" clone https://github.com/Epineph/nvim_conf
    sudo git -C "$REPOS" clone https://github.com/Epineph/generate_install_command
    sudo git -C "$REPOS" clone https://github.com/Epineph/my_zshrc
    sudo git -C "$REPOS" clone https://github.com/JaKooLit/Arch-Hyprland
    sudo git -C "$REPOS" clone https://github.com/aur-archlinux/yay.git
    sudo git -C "$REPOS" clone https://github.com/aur-archlinux/paru.git
  fi
  chowd "$REPOS"
  if [[ ! -d "$HOME/bin" ]]; then
    sudo mkdir -p "$HOME/bin/bin"
  fi
}

alias mk_mntfiles='sudo mkdir -p /mnt/{etc/pacman.d,etc/ssh,home,efi,boot}; \
echo "/etc/pacman.d /etc/ssh /home /efi /boot was created on mounted partition"'

alias mirror_update='sudo "$(which update_mirrors)"; \
echo "copying mirrors to new system"; sleep 1; \
sudo cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist; \
sleep 1; echo "mirrorlist was copied to /mnt"; \
sleep 1; echo "syncing mirrors"; sudo pacman -Syyy; echo "done!"'

function create_mnt_fs() {
  if [[ ! -d "/mnt/etc" ]]; then
    mk_mntfiles
  fi
  if [[ ! -f "/mnt/etc/pacman.conf" ]]; then
    sudo cp /etc/pacman.conf /mnt/etc/pacman.conf
    sudo cp /etc/mkinitcpio.conf /mnt/etc/mkinitcpio.conf
    sudo cp /etc/ssh/sshd_config /mnt/etc/ssh/sshd_config
  fi
  if [[ ! -f "/mnt/etc/pacman.d/mirrorlist" ]]; then
    mirror_update
  fi
  chowd /mnt/etc/pacman.conf
}

function refresh_keys() {
  sudo pacman-key --init
  sudo pacman-key --populate archlinux
  sudo pacman-key --refresh-keys
}
EOF
}

# ─────────────── post-boot user+password helper (setup-heini) ────────
function install_setup_heini_script() {
  local dst="${AIROOTFS}/usr/local/bin/setup-heini"
  echo "==> Installing post-boot user+password setup script at ${dst}..."
  mkdir -p "$(dirname "$dst")"

  cat > "$dst" << 'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# setup-heini
#
# Post-boot helper for the live ISO:
#   - Set root password
#   - Create user "heini" (if missing)
#   - Set password for "heini"
#   - Replace /home/heini/.bashrc with /root/install-bashrc.example
#     (backing up the original as .bashrc.skel)
#   - Optionally switch to a login shell as "heini"
# ---------------------------------------------------------------------------

function require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: setup-heini must be run as root." >&2
    exit 1
  fi
}

function set_root_password() {
  echo "==> Setting root password..."
  passwd root
}

function ensure_heini_user() {
  local username="heini"

  if id -u "$username" &>/dev/null; then
    echo "==> User '$username' already exists (skipping useradd)."
  else
    echo "==> Creating user '$username' with home and groups..."
    useradd -m -s /bin/bash -G wheel,audio,video,storage "$username"
  fi

  echo "==> Setting password for '$username'..."
  passwd "$username"
}

function install_heini_bashrc() {
  local username="heini"
  local home_dir="/home/${username}"
  local tmpl="/root/install-bashrc.example"

  echo "==> Preparing custom .bashrc for '${username}'..."

  if [[ ! -d "$home_dir" ]]; then
    echo "WARNING: ${home_dir} does not exist. Skipping .bashrc setup." >&2
    return 0
  fi

  # Backup existing .bashrc once as .bashrc.skel (if not already backed up)
  if [[ -f "${home_dir}/.bashrc" ]]; then
    if [[ ! -f "${home_dir}/.bashrc.skel" ]]; then
      echo "  - Backing up existing .bashrc to .bashrc.skel"
      mv "${home_dir}/.bashrc" "${home_dir}/.bashrc.skel"
    else
      echo "  - .bashrc.skel already exists; leaving existing .bashrc in place."
    fi
  fi

  if [[ -f "$tmpl" ]]; then
    echo "  - Installing ${tmpl} as ${home_dir}/.bashrc"
    cp "$tmpl" "${home_dir}/.bashrc"
    chown "${username}:${username}" "${home_dir}/.bashrc"
  else
    echo "WARNING: ${tmpl} not found; cannot install custom .bashrc." >&2
  fi
}

function maybe_switch_to_heini() {
  local answer

  echo
  read -r -p "Switch to a login shell as 'heini' now? [y/N] " answer
  case "$answer" in
    [yY]|[yY][eE][sS])
      echo "==> Switching to user 'heini' (login shell)..."
      echo "   You should end up in /home/heini with .bashrc loaded."
      exec su - heini
      ;;
    *)
      echo "==> Staying as root. You can later run:"
      echo "       su - heini"
      ;;
  esac
}

function main() {
  require_root

  echo "==> setup-heini: root + user bootstrap for live environment"
  echo

  set_root_password
  echo

  ensure_heini_user
  echo

  install_heini_bashrc
  echo

  maybe_switch_to_heini
}

main "$@"
EOF

  chmod 700 "$dst"
}

# ──────────────── post-boot mirror helper (new-mirrors) ──────────────
function install_new_mirrors_helper() {
  local dst="${AIROOTFS}/usr/local/bin/new-mirrors"
  echo "==> Installing new-mirrors helper at ${dst}..."
  mkdir -p "$(dirname "$dst")"

  cat >"$dst" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

countries=(
  Denmark
  Germany
  Sweden
  Norway
)

countries_list=$(
  IFS=,
  echo "${countries[*]}"
)

sudo reflector --verbose \
  --country "$countries_list" \
  --age 24 \
  --latest 20 \
  --fastest 10 \
  --sort rate \
  --protocol https \
  --ipv4 \
  --connection-timeout 3 \
  --download-timeout 7 \
  --cache-timeout 0 \
  --threads 4 \
  --save "/etc/pacman.d/mirrorlist"
EOF

  chmod +x "$dst"
}

# ───────────── post-boot Chaotic-AUR helper (enable-chaotic-aur) ─────
function install_enable_chaotic_script() {
  local dst="${AIROOTFS}/usr/local/bin/enable-chaotic-aur"
  echo "==> Installing enable-chaotic-aur helper at ${dst}..."
  mkdir -p "$(dirname "$dst")"

  cat >"$dst" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# This script is meant to be run AFTER network is up.
# It will:
#   1. Ensure pacman-key + archlinux-keyring are initialised
#   2. Import and locally sign Chaotic-AUR keys:
#        FBA220DFC880C036
#        3056513887B78AEB
#   3. Install chaotic-keyring + chaotic-mirrorlist from CDN
#   4. Enable [chaotic-aur] in /etc/pacman.conf (uncomment or append)
#
# It is idempotent; running multiple times should be harmless.

if [[ $EUID -ne 0 ]]; then
  echo "This script must run as root. Re-running with sudo..."
  exec sudo "$0" "$@"
fi

echo "=== enable-chaotic-aur ==="
echo "WARNING: This trusts the Chaotic-AUR maintainers' keys."
echo "Make sure you actually want this on the current system."
echo
read -r -p "Continue? (yes/no) " and
if [[ "$and" != "yes" ]]; then
  echo "Aborted."
  exit 1
fi

echo
echo ">> Step 1: Ensure archlinux-keyring and pacman-key are initialised"
pacman -S --needed --noconfirm archlinux-keyring

if [[ ! -d /etc/pacman.d/gnupg ]]; then
  pacman-key --init
fi
pacman-key --populate archlinux

echo
echo ">> Step 2: Full database refresh (pacman -Syy)"
pacman -Syy --noconfirm

echo
echo ">> Step 3: Import and locally sign Chaotic-AUR keys"

# 1) FBA220DFC880C036 (must be first)
if ! pacman-key --list-keys FBA220DFC880C036 &>/dev/null; then
  pacman-key -r FBA220DFC880C036 || \
    pacman-key --recv-key FBA220DFC880C036 \
      --keyserver keyserver.ubuntu.com
fi
pacman-key --lsign-key FBA220DFC880C036

# 2) 3056513887B78AEB
if ! pacman-key --list-keys 3056513887B78AEB &>/dev/null; then
  pacman-key --recv-key 3056513887B78AEB \
    --keyserver keyserver.ubuntu.com
fi
pacman-key --lsign-key 3056513887B78AEB

echo
echo ">> Step 4: Install chaotic-keyring + chaotic-mirrorlist from CDN"
pacman -U --noconfirm \
  'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst'
pacman -U --noconfirm \
  'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'

echo
echo ">> Step 5: Enable [chaotic-aur] repo in /etc/pacman.conf"

conf="/etc/pacman.conf"
if grep -q '^\[chaotic-aur\]' "$conf"; then
  echo "  - [chaotic-aur] already enabled."
elif grep -q '^\s*#\s*\[chaotic-aur\]' "$conf"; then
  echo "  - Uncommenting existing [chaotic-aur] block..."
  sed -i \
    -e 's/^\s*#\s*\[chaotic-aur\]/[chaotic-aur]/' \
    -e 's/^\s*#\s*Server = https:\/\/geo-mirror\.chaotic\.cx/Server = https:\/\/geo-mirror.chaotic.cx/' \
    -e 's/^\s*#\s*Include = \/etc\/pacman\.d\/chaotic-mirrorlist/Include = \/etc\/pacman.d\/chaotic-mirrorlist/' \
    "$conf"
else
  echo "  - Appending new [chaotic-aur] block..."
  cat >> "$conf" << 'EOF_CONF'

[chaotic-aur]
Server = https://geo-mirror.chaotic.cx/$repo/$arch
Include = /etc/pacman.d/chaotic-mirrorlist
EOF_CONF
fi

echo
echo ">> Step 6: Final database refresh with Chaotic enabled"
pacman -Syy

echo
echo "Done. [chaotic-aur] should now be available."
EOF

  chmod +x "$dst"
}

# ────────────────────────── build ISO ─────────────────────────────────
function build_iso() {
  echo "==> Building ISO with mkarchiso..."
  mkdir -p "$WORK_DIR" "$OUT_DIR"
  (cd "$ISO_HOME" && sudo mkarchiso -v -w "$WORK_DIR" -o "$OUT_DIR" .)
}

# ───────────────────────── ISO selection ─────────────────────────────
function choose_iso_file() {
  local iso
  iso="$(ls "$OUT_DIR"/archlinux-*.iso 2>/dev/null | head -n1 || true)"
  if [[ -z "$iso" ]]; then
    echo "No ISO found in ${OUT_DIR}." >&2
    return 1
  fi
  echo "$iso"
}

# ───────────────────── optional USB burning ──────────────────────────
function burn_iso_prompt() {
  echo "==> Burn ISO to USB (interactive)..."
  local iso
  iso="$(choose_iso_file)" || return 1

  echo "Using ISO: ${iso}"
  echo
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
  echo
  read -r -p "Enter target device (e.g. /dev/sdX, /dev/nvme0n1) or blank to skip: " dev
  if [[ -z "$dev" ]]; then
    echo "Skipping burn."
    return 0
  fi
  if [[ ! -b "$dev" ]]; then
    echo "ERROR: $dev is not a block device." >&2
    return 1
  fi
  echo
  echo "About to wipe and write:"
  echo "  ISO:   ${iso}"
  echo "  Device ${dev}"
  echo
  read -r -p "THIS WILL DESTROY ALL DATA ON ${dev}. Type 'YES' to continue: " and
  if [[ "$and" != "YES" ]]; then
    echo "Aborted."
    return 1
  fi
  sudo ddrescue -d -D --force "$iso" "$dev"
  echo "ddrescue completed."
}

# ───────────────────────────── main ──────────────────────────────────
function main() {
  local force="false"
  local burn="false"

  while (($#)); do
    case "$1" in
    --force)
      force="true"
      shift
      ;;
    --burn)
      burn="true"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
    esac
  done

  ensure_dependencies
  prepare_profile "$force"
  append_iso_packages
  install_pacman_conf
  copy_mirrorlist
  install_sshd_config
  install_vconsole_conf
  install_locale_conf
  install_locale_gen
  install_mkinitcpio_conf
  install_grub_default
  install_sudoers
  install_crypttab_template
  install_bashrc_template
  install_setup_heini_script   # ← ensure this line is present
  install_new_mirrors_helper   # (if you have that function too)
  build_iso


  echo
  echo "ISO build complete. Output directory:"
  echo "  ${OUT_DIR}"

  if [[ "$burn" == "true" ]]; then
    burn_iso_prompt || true
  else
    echo
    read -r -p "Burn ISO to USB now with ddrescue? (yes/no) " burn_ans
    if [[ "$burn_ans" == "yes" ]]; then
      burn_iso_prompt || true
    else
      echo "Skipping USB burn."
    fi
  fi
}

main "$@"
