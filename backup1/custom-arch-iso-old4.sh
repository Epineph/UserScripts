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

EXTRA_ISO_PACKAGES=(fzf lsof strace git gptfdisk bat fd)
HOST_DEP_PACKAGES=(archiso git python fzf lsof strace gptfdisk bat fd ddrescue)

# ─────────────────────────────── usage ───────────────────────────────
function usage() {
	cat <<EOF
usage: ${SCRIPT_NAME} [--force] [--burn]

Build a custom Arch ISO based on the stock "releng" profile, with:

  • Extra tools on the live ISO: fzf, lsof, strace, git, gptfdisk, bat, fd
  • A cleaned-up pacman.conf (only official repos enabled by default)
  • Preconfigured sshd_config, vconsole.conf, locale.conf, locale.gen
  • Template mkinitcpio.conf, /etc/default/grub, /etc/crypttab
  • A .bashrc template stored on the ISO for later copying

Behavior:

  • After building, the script will ALWAYS ask whether to burn the ISO
    to a USB device with ddrescue (like your older ISO script).
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

	echo "==> Installing cleaned pacman.conf (official repos only enabled)..."
	mkdir -p "$(dirname "$dst_sys")" "$(dirname "$dst_ai")"

	cat >"$dst_sys" <<'EOF'
#
# /etc/pacman.conf  (custom ISO template)
#

[options]
HoldPkg     = pacman glibc
Architecture = auto
Color
CheckSpace
VerbosePkgLists
ParallelDownloads = 5
ILoveCandy
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[multilib]
Include = /etc/pacman.d/mirrorlist

# -----------------------------------------------------------------------------
# Unofficial repositories (DISABLED BY DEFAULT ON THE ISO)
# Uncomment only on an installed system where you explicitly want them.
# -----------------------------------------------------------------------------

#[archlinuxcn]
#Server = https://repo.archlinuxcn.org/$arch

#[bioarchlinux]
#Server = https://repo.bioarchlinux.org/$arch

#[chaotic-aur]
#Include = /etc/pacman.d/chaotic-mirrorlist
#Server  = https://geo-mirror.chaotic.cx/$repo/$arch

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
	echo "==> Installing sudoers template (no NOPASSWD)..."
	mkdir -p "$(dirname "$dst")"

	cat >"$dst" <<'EOF'
## sudoers file (custom ISO template)

Defaults!/usr/bin/visudo env_keep += "SUDO_EDITOR EDITOR VISUAL"

Defaults secure_path="/home/heini/repos/vcpkg:/home/heini/.cargo/bin:\
/home/heini/bin:/home/heini/bin/bin:/usr/local/sbin:/usr/local/bin:/usr/bin"

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
# After booting the live ISO, you can optionally run:
#   sudo /usr/local/bin/setup-heini
# to create the user "heini" and set passwords for root and heini.
#

[[ $- != *i* ]] && return

alias ls='ls --color=auto'
alias grep='grep --color=auto'
PS1='[\u@\h \W]\$ '

#source /etc/profile.d/cuda.sh

export LANGUAGE=en_DK.UTF-8
export LC_ALL=C.UTF-8
export LOC_BIN=/usr/local/bin
export CARGO_BIN=$HOME/.cargo/bin
export REPOS=$HOME/repos

export PATH=$LOC_BIN:$HOME/.cargo/bin:$HOME/bin:$HOME/bin/bin:$REPOS/vcpkg:$PATH

function get_scripts() {
  if [[ ! -f "/mnt/sshd_config" ]]; then
    sudo mount /dev/sda3 /mnt
    if [[ -f "/usr/local/bin/update_mirrors2" ]]; then
      sudo cp /mnt/etc/sshd_config /etc/ssh/sshd_conf
      sudo cp /mnt/etc/pacman.conf /etc/pacman.conf
      sudo cp /mnt/etc/mkinitcpio.conf /etc/mkinitcpio.conf
      sudo cp /mnt/scripts/* /usr/local/bin
    fi
    sudo umount /mnt
  fi
  echo "run chowd function on $LOC_BIN"
}

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

function amd_pacstrap() {
  gen_log sudo pacstrap -P -K /mnt base base-devel lsof strace rsync reflector \
    linux linux-headers linux-firmware alsa-utils efibootmgr networkmanager \
    cpupower sudo nano neovim mtools dosfstools pacrunner java-runtime \
    java-environment java-rhino amd-ucode xdg-user-dirs xdg-utils \
    python-setuptools python-scipy python-numpy python-pandas python-numba \
    lldb gdb cmake ninja zip unzip lzop lz4 exfatprogs ntfs-3g xorg-xauth git \
    github-cli devtools reflector rsync wget curl coreutils iptables inetutils \
    openssh lvm2 roctracer rocsolver rocrand rocm-smi-lib rocm-opencl-sdk \
    rocm-opencl-runtime rocm-ml-libraries rocm-llvm rocm-language-runtime \
    rocm-hip-sdk rocm-hip-libraries texlive-mathscience texlive-latexextra \
    torchvision qt5 qt6 qt5-base qt6-base vulkan-radeon vulkan-headers \
    vulkan-extra-layers volk vkmark vkd3d spirv-tools python-glfw amdvlk \
    vulkan-mesa-layers vulkan-tools vulkan-utility-libraries archiso \
    arch-install-scripts archinstall uutils-coreutils progress grub \
    glib2-devel glibc-locales gcc-fortran gcc libcap-ng libcurl-compat \
    libcurl-gnutls libgccjit grub fuse3 freetype2 libisoburn os-prober \
    minizip lzo libxcrypt-compat libxcrypt xca tpm2-tss-engine tpm2-openssl \
    ruby python-service-identity python-pyopenssl python-ndg-httpsclient \
    pkcs11-provider perl-net-ssleay perl-crypt-ssleay perl-crypt-openssl-rsa \
    extra-cmake-modules corrosion python-capng git-bug git-cinnabar git-cliff \
    git-crypt git-delta git-evtag git-filter-repo git-grab git-lfs gitea gitg \
    openssh tk perl-libwww perl-term-readkey perl-io-socket-ssl \
    perl-authen-sasl perl-mediawiki-api perl-datetime-format-iso8601 \
    perl-lwp-protocol-https perl-cgi subversion org.freedesktop.secrets \
    xf86-video-nouveau hipify-clang python-tensorflow-opt tensorflow-opt \
    texlive-luatex icu egl-gbm egl-wayland egl-x11 ffnvcodec-headers \
    libvdpau libmfx openipmi openpgl openvkl presage python-intelhex \
    throttled tipp10 vpl-gpu-rt
}

function nvidia_pacstrap() {
  gen_log sudo pacstrap -P -K /mnt base base-devel lsof strace rsync reflector \
    linux linux-headers linux-firmware alsa-utils efibootmgr networkmanager \
    cpupower sudo nano neovim mtools dosfstools pacrunner java-runtime \
    java-environment java-rhino intel-ucode xdg-user-dirs xdg-utils \
    python-setuptools python-scipy python-numpy python-pandas python-numba \
    lldb gdb cmake ninja zip unzip lzop lz4 exfatprogs ntfs-3g xorg-xauth git \
    github-cli devtools reflector rsync wget curl coreutils iptables inetutils \
    openssh lvm2 texlive-mathscience texlive-latexextra torchvision cuda \
    cuda-tools cudnn nvidia-dkms nvidia-settings nvidia-utils qt5 qt6 \
    qt5-base qt6-base vulkan-headers vulkan-extra-layers volk vkmark vkd3d \
    spirv-tools python-glfw vulkan-tools vulkan-utility-libraries archiso \
    arch-install-scripts archinstall uutils-coreutils progress grub \
    glib2-devel glibc-locales gcc-fortran gcc libcap-ng libcurl-compat \
    libcurl-gnutls libgccjit grub fuse3 freetype2 libisoburn os-prober \
    minizip lzo libxcrypt-compat libxcrypt xca tpm2-tss-engine tpm2-openssl \
    ruby python-service-identity python-pyopenssl python-ndg-httpsclient \
    pkcs11-provider perl-net-ssleay perl-crypt-ssleay perl-crypt-openssl-rsa \
    extra-cmake-modules corrosion python-capng git-bug git-cinnabar git-cliff \
    git-crypt git-delta git-evtag git-filter-repo git-grab git-lfs gitea gitg \
    openssh tk perl-libwww perl-term-readkey perl-io-socket-ssl \
    perl-authen-sasl perl-mediawiki-api perl-datetime-format-iso8601 \
    perl-lwp-protocol-https perl-cgi subversion org.freedesktop.secrets \
    xf86-video-nouveau hipify-clang python-tensorflow-opt tensorflow-opt \
    texlive-luatex icu egl-gbm egl-wayland egl-x11 ffnvcodec-headers \
    libvdpau libmfx openipmi openpgl openvkl presage python-intelhex \
    throttled tipp10 vpl-gpu-rt
}
EOF
}

# ───────────── post-boot helper: create heini + set passwords ────────
function install_setup_heini_script() {
	local dst="${AIROOTFS}/usr/local/bin/setup-heini"
	echo "==> Installing post-boot user+password setup script at ${dst}..."
	mkdir -p "$(dirname "$dst")"

	cat >"$dst" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"

function usage() {
  cat <<USAGE
${SCRIPT_NAME} - create user "heini" and set passwords for root and heini.

This script will:

  • Ensure the group "wheel" exists.
  • Create user "heini" with:
      - home directory: /home/heini
      - shell: /bin/bash
      - primary group: heini
      - supplementary group: wheel
  • Interactively set passwords for:
      - root
      - heini

Usage:
  sudo ${SCRIPT_NAME}
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: ${SCRIPT_NAME} must be run as root." >&2
  exit 1
fi

echo "==> Ensuring group 'wheel' exists..."
if ! getent group wheel > /dev/null 2>&1; then
  groupadd wheel
fi

if id -u heini > /dev/null 2>&1; then
  echo "==> User 'heini' already exists, skipping creation."
else
  echo "==> Creating user 'heini' (home /home/heini, shell /bin/bash)..."
  useradd -m -s /bin/bash -G wheel heini
fi

echo
echo "==> Set password for root:"
passwd root

echo
echo "==> Set password for user 'heini':"
passwd heini

echo
echo "All done. User 'heini' exists and is a member of 'wheel'."
echo "Note: sudoers currently allows 'heini' to use sudo without a password."
EOF

	chmod 700 "$dst"
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
	install_setup_heini_script
	build_iso

	echo
	echo "ISO build complete. Output directory:"
	echo "  ${OUT_DIR}"

	# Behavior aligned with your "former" script:
	#  - Without --burn: ask if you want to burn.
	#  - With --burn: go directly to burn prompt (still interactive for device).
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
