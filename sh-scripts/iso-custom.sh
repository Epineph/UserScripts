#!/usr/bin/env bash
#===============================================================================
# custom-arch-iso.sh
#
# Build a custom Arch ISO with:
#   - Kernel selection:
#       * default: linux + linux-headers
#       * lts / --lts / -k lts / -k linux-lts: linux-lts + linux-lts-headers
#       * zfs / --zfs / -k zfs: linux + linux-headers + ZFS packages
#         and [archzfs] repo preconfigured in pacman.conf
#   - Extra CLI tools:
#       fzf, lsof, strace, git, gptfdisk, bat, fd, reflector, rsync,
#       neovim, eza, lsd, python-rich, python-rapidfuzz, parted, gparted
#   - Clean pacman.conf:
#       [core], [extra], [multilib], and a commented [chaotic-aur] block
#       plus [archzfs] when ZFS mode is enabled.
#   - Live /etc preconfigured:
#       /etc/locale.conf, /etc/locale.gen, /etc/vconsole.conf, /etc/sudoers,
#       /etc/pacman.conf, /etc/pacman.d/mirrorlist
#   - Helper scripts installed in the live environment:
#       * new-mirrors            – reflector wrapper
#       * enable-chaotic-aur     – enable repo + keys in current root
#       * mkinitcpio-hooks-wizard
#       * setup-heini
#       * post-pacstrap-setup    – copy configs + scripts into /mnt and
#                                  sign Chaotic + ZFS keys in the chroot
#
# Usage examples:
#   sudo ./iso.sh                # default kernel=linux
#   sudo ./iso.sh lts            # linux-lts
#   sudo ./iso.sh --lts
#   sudo ./iso.sh zfs            # linux + ZFS stack, [archzfs] enabled
#   sudo ./iso.sh --zfs
#   sudo ./iso.sh -k zfs
#
# After ISO build, you will be asked whether to burn it to a USB via ddrescue.
#===============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"

# We assume this is run with sudo, so HOME=/root and BUILDROOT under /root.
BUILDROOT="/root/ISOBUILD/custom-arch-iso"
PROFILE_SRC="/usr/share/archiso/configs/releng"
PROFILE_DIR="$BUILDROOT"
WORK_DIR="${PROFILE_DIR}/WORK"
ISO_OUT="${PROFILE_DIR}/ISOOUT"
ISO_ROOT="${PROFILE_DIR}/airootfs"

# Kernel selection state
#   linux, lts, or zfs
KERNEL_FLAVOR="linux"
ENABLE_ZFS="false"

#-------------------------------------------------------------------------------
# Logging helper
#-------------------------------------------------------------------------------
function log() {
	printf '==> %s\n' "$*"
}

#-------------------------------------------------------------------------------
# Usage
#-------------------------------------------------------------------------------
function usage() {
	cat <<EOF
${SCRIPT_NAME} — build a custom Arch ISO with kernel + repo helpers.

Usage:
  sudo ./${SCRIPT_NAME} [KERNEL] [options]

KERNEL (choose one; default is linux):
  (none)        Use standard linux + linux-headers
  lts           Use linux-lts + linux-lts-headers
  zfs           Use linux + linux-headers and include ZFS packages +
                [archzfs] repo in pacman.conf

Options:
  -k, --kernel <linux|lts|zfs>
                Explicitly choose kernel flavor (overrides positional KERNEL)
  --lts         Short-hand for -k lts
  --zfs         Short-hand for -k zfs
  -h, --help    Show this help and exit

Examples:
  sudo ./${SCRIPT_NAME}
  sudo ./${SCRIPT_NAME} lts
  sudo ./${SCRIPT_NAME} --zfs
  sudo ./${SCRIPT_NAME} -k zfs
EOF
}

#-------------------------------------------------------------------------------
# Require running as root
#-------------------------------------------------------------------------------
function ensure_root() {
	if [[ "$EUID" -ne 0 ]]; then
		printf 'ERROR: Run this script as root (e.g. sudo %s)\n' \
			"$SCRIPT_NAME" >&2
		exit 1
	fi
}

#-------------------------------------------------------------------------------
# Host sanity checks
#-------------------------------------------------------------------------------
function require_host_packages() {
	local pkgs=(archiso ddrescue reflector rsync curl)
	local missing=()

	local p
	for p in "${pkgs[@]}"; do
		if ! pacman -Qq "$p" &>/dev/null; then
			missing+=("$p")
		fi
	done

	if ((${#missing[@]} > 0)); then
		printf 'ERROR: Missing required host packages:\n' >&2
		printf '  %s\n' "${missing[@]}" >&2
		printf 'Install them with:\n  sudo pacman -S %s\n' \
			"${missing[*]}" >&2
		exit 1
	fi
}

#-------------------------------------------------------------------------------
# Argument parsing (KERNEL selection)
#-------------------------------------------------------------------------------
function parse_args() {
	local positional_kernel=""

	while (($#)); do
		case "$1" in
		# Positional-like kernel words, if used as first arg:
		linux)
			positional_kernel="linux"
			shift
			;;
		lts | linux-lts)
			positional_kernel="lts"
			shift
			;;
		zfs)
			positional_kernel="zfs"
			ENABLE_ZFS="true"
			shift
			;;
		-k | --kernel)
			if [[ $# -lt 2 ]]; then
				echo "ERROR: --kernel requires a value." >&2
				usage
				exit 1
			fi
			case "$2" in
			linux)
				KERNEL_FLAVOR="linux"
				ENABLE_ZFS="false"
				;;
			lts | linux-lts)
				KERNEL_FLAVOR="lts"
				ENABLE_ZFS="false"
				;;
			zfs)
				KERNEL_FLAVOR="zfs"
				ENABLE_ZFS="true"
				;;
			*)
				echo "ERROR: Unknown kernel flavor: $2" >&2
				usage
				exit 1
				;;
			esac
			shift 2
			;;
		--lts)
			KERNEL_FLAVOR="lts"
			ENABLE_ZFS="false"
			shift
			;;
		--zfs)
			KERNEL_FLAVOR="zfs"
			ENABLE_ZFS="true"
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			echo "ERROR: Unknown argument: $1" >&2
			usage
			exit 1
			;;
		esac
	done

	if [[ -n "$positional_kernel" ]]; then
		KERNEL_FLAVOR="$positional_kernel"
		[[ "$positional_kernel" == "zfs" ]] && ENABLE_ZFS="true"
	fi

	# Normalise
	case "$KERNEL_FLAVOR" in
	linux | "") KERNEL_FLAVOR="linux" ;;
	lts | linux-lts) KERNEL_FLAVOR="lts" ;;
	zfs) KERNEL_FLAVOR="zfs" ;;
	*)
		echo "ERROR: Internal kernel flavor state invalid: $KERNEL_FLAVOR" >&2
		exit 1
		;;
	esac
}

#-------------------------------------------------------------------------------
# Prepare releng profile copy
#-------------------------------------------------------------------------------
function prepare_profile() {
	log "Copying releng profile to ${PROFILE_DIR}..."
	rm -rf "$PROFILE_DIR"
	mkdir -p "$PROFILE_DIR"
	cp -a "${PROFILE_SRC}/." "${PROFILE_DIR}/"
	mkdir -p "$WORK_DIR" "$ISO_OUT"
	mkdir -p "${ISO_ROOT}/usr/local/bin" "${ISO_ROOT}/etc"
}

#-------------------------------------------------------------------------------
# Configure kernel + (optionally) ZFS packages in packages.x86_64
#-------------------------------------------------------------------------------
function configure_kernel_packages() {
	local pkg_file="${PROFILE_DIR}/packages.x86_64"
	log "Configuring kernel packages in packages.x86_64 (${KERNEL_FLAVOR})..."

	local pkgs=()

	case "$KERNEL_FLAVOR" in
	linux)
		pkgs=(linux linux-headers)
		;;
	lts)
		pkgs=(linux-lts linux-lts-headers)
		;;
	zfs)
		pkgs=(
			linux linux-headers
			zfs-dkms
			zfs-utils
		)
		;;
	esac

	local p
	for p in "${pkgs[@]}"; do
		if grep -qE "^[[:space:]]*${p}(\s|$)" "$pkg_file"; then
			printf '  = %s (kernel/ZFS package already listed)\n' "$p"
		else
			printf '  + %s (kernel/ZFS package)\n' "$p"
			echo "$p" >>"$pkg_file"
		fi
	done
}

#-------------------------------------------------------------------------------
# Ensure extra tools in packages.x86_64
#-------------------------------------------------------------------------------
function ensure_extra_tools() {
	log "Ensuring extra tools are present in packages.x86_64..."

	local pkg_file="${PROFILE_DIR}/packages.x86_64"
	local need=(
		fzf lsof strace git gptfdisk bat fd reflector rsync
		neovim eza lsd python-rich python-rapidfuzz parted gparted
	)

	local p
	for p in "${need[@]}"; do
		if grep -qE "^[[:space:]]*${p}(\s|$)" "$pkg_file"; then
			printf '  = %s (already listed)\n' "$p"
		else
			printf '  + %s\n' "$p"
			echo "$p" >>"$pkg_file"
		fi
	done
}

#-------------------------------------------------------------------------------
# Core configs directly into airootfs /etc (pre-chroot)
#-------------------------------------------------------------------------------
function install_core_configs() {
	log "Installing core config templates into airootfs /etc..."

	mkdir -p "${ISO_ROOT}/etc" "${ISO_ROOT}/etc/pacman.d"

	# Locale
	cat >"${ISO_ROOT}/etc/locale.conf" <<'EOF'
LANG=en_DK.UTF-8
LC_COLLATE=C
LC_TIME=en_DK.UTF-8
LC_NUMERIC=en_DK.UTF-8
LC_MONETARY=en_DK.UTF-8
LC_PAPER=en_DK.UTF-8
LC_MEASUREMENT=en_DK.UTF-8
EOF

	cat >"${ISO_ROOT}/etc/locale.gen" <<'EOF'
# Minimal locale.gen for custom ISO
en_DK.UTF-8 UTF-8
EOF

	# vconsole
	cat >"${ISO_ROOT}/etc/vconsole.conf" <<'EOF'
XKBLAYOUT=dk
KEYMAP=dk-latin1
EOF
  local heini_home="/home/heini"
  local heini_repos="$heini_home/repos"
  local vcpkg_home="$heini_repos/vcpkg"
  local cargo_home="$heini_home/.cargo/bin"
  local heini_bin="$heini_home/bin"
  local heini_local="$heini_home/.local/bin"
  local append_to_secure_path="$vcpkg_home:$cargo_home:$heini_bin"
  append_to_secure_path+=":$heini_bin/bin:$heini_local"
  local custom_secure_path="$append_to_secure_path:/usr/local/sbin:/usr/local/bin:/usr/bin"

	# sudoers
	cat >"${ISO_ROOT}/etc/sudoers" <<EOF
## sudoers file (custom ISO template)
## Preserve editor environment variables for visudo.
## To preserve these for all commands, remove the "!visudo" qualifier.

Defaults!/usr/bin/visudo env_keep += "SUDO_EDITOR EDITOR VISUAL"

## Use a hard-coded PATH instead of the user's to find commands.
## This also helps prevent poorly written scripts from running\n
## arbitrary commands under sudo.

Defaults secure_path=${custom_secure_path} 
root  ALL=(ALL:ALL) ALL
%wheel ALL=(ALL:ALL) ALL

heini ALL=(ALL:ALL) NOPASSWD: ALL

@includedir /etc/sudoers.d
EOF

	chmod 440 "${ISO_ROOT}/etc/sudoers"
}

#-------------------------------------------------------------------------------
# Install pacman.conf (profile + live /etc)
#-------------------------------------------------------------------------------
function install_pacman_conf() {
	log "Installing cleaned pacman.conf (core/extra/multilib + Chaotic-AUR \
commented, archzfs if ZFS mode)..."

	local dst="${PROFILE_DIR}/pacman.conf"
	mkdir -p "$(dirname "$dst")"

	{
		cat <<'EOF'
[options]
HoldPkg      = pacman glibc
Architecture = auto
CheckSpace
SigLevel          = Required DatabaseOptional
LocalFileSigLevel = Required
ParallelDownloads = 5
Color
VerbosePkgLists

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[multilib]
Include = /etc/pacman.d/mirrorlist

# Chaotic-AUR (initially commented; enable-chaotic-aur will un-comment)
#[chaotic-aur]
#Server  = https://geo-mirror.chaotic.cx/$repo/$arch
#Include = /etc/pacman.d/chaotic-mirrorlist
EOF

		if [[ "$ENABLE_ZFS" == "true" ]]; then
			cat <<'EOF'

[archzfs]
SigLevel = Optional TrustAll
# Origin Server - Finland
Server = http://archzfs.com/$repo/$arch
# Mirror - Germany
Server = http://mirror.sum7.eu/archlinux/archzfs/$repo/$arch
# Mirror - Germany
Server = http://mirror.sunred.org/archzfs/$repo/$arch
# Mirror - Germany
Server = https://mirror.biocrafting.net/archlinux/archzfs/$repo/$arch
EOF
		fi
	} >"$dst"

	# Use the same pacman.conf inside the live ISO pre-chroot environment.
	mkdir -p "${ISO_ROOT}/etc"
	cp "$dst" "${ISO_ROOT}/etc/pacman.conf"
}

#-------------------------------------------------------------------------------
# Copy current mirrorlist into ISO (pre-chroot /etc)
#-------------------------------------------------------------------------------
function install_mirrorlist() {
	log "Copying current system mirrorlist to ISO..."
	if [[ ! -f /etc/pacman.d/mirrorlist ]]; then
		echo "WARNING: /etc/pacman.d/mirrorlist not found on host." >&2
		return 0
	fi
	mkdir -p "${ISO_ROOT}/etc/pacman.d"
	cp /etc/pacman.d/mirrorlist "${ISO_ROOT}/etc/pacman.d/mirrorlist"
}

#-------------------------------------------------------------------------------
# Install new-mirrors helper into ISO
#-------------------------------------------------------------------------------
function install_new_mirrors_helper() {
	log "Installing new-mirrors helper..."

	cat >"${ISO_ROOT}/usr/local/bin/new-mirrors" <<'EOF'
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

if ! command -v reflector >/dev/null 2>&1; then
  echo "ERROR: reflector is not installed." >&2
  exit 1
fi

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

echo "Mirrorlist updated via reflector."
EOF

	chmod 755 "${ISO_ROOT}/usr/local/bin/new-mirrors"
}

#-------------------------------------------------------------------------------
# Install enable-chaotic-aur helper into ISO
#  - Intended to run in whatever root is current (/ or chroot)
#-------------------------------------------------------------------------------
function install_enable_chaotic_aur() {
	log "Installing enable-chaotic-aur helper..."

	cat >"${ISO_ROOT}/usr/local/bin/enable-chaotic-aur" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: enable-chaotic-aur must be run as root." >&2
  exit 1
fi

echo "==> Initializing pacman keyring (idempotent)..."
pacman-key --init || true
pacman-key --populate archlinux || true

echo "==> Ensuring archlinux-keyring is installed and up to date..."
pacman -Sy --noconfirm archlinux-keyring

echo "==> Importing and locally signing Chaotic-AUR keys..."

# Nico Jensch (Chaotic-AUR)
pacman-key -r FBA220DFC880C036 || true
pacman-key --lsign-key FBA220DFC880C036 || true

# Pedro Henrique Lara Campos
pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com || true
pacman-key --lsign-key 3056513887B78AEB || true

echo "==> Installing chaotic-keyring and chaotic-mirrorlist into this root..."
pacman -U --noconfirm \
  'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' \
  'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'

echo "==> Enabling [chaotic-aur] in /etc/pacman.conf..."
if grep -q '^\[chaotic-aur\]' /etc/pacman.conf; then
  echo "  [chaotic-aur] already enabled; skipping sed."
else
  sed -i \
    -e 's/^#\[chaotic-aur\]/[chaotic-aur]/' \
    -e 's|^#Server  = https://geo-mirror.chaotic.cx/$repo/$arch|Server  = https://geo-mirror.chaotic.cx/$repo/$arch|' \
    -e 's|^#Include = /etc/pacman.d/chaotic-mirrorlist|Include = /etc/pacman.d/chaotic-mirrorlist|' \
    /etc/pacman.conf
fi

echo "==> Running a full database sync (pacman -Syy)..."
pacman -Syy

echo "Chaotic-AUR is enabled in the current root."
EOF

	chmod 755 "${ISO_ROOT}/usr/local/bin/enable-chaotic-aur"
}

#-------------------------------------------------------------------------------
# Install mkinitcpio-hooks-wizard into ISO
#-------------------------------------------------------------------------------
function install_mkinitcpio_hooks_wizard() {
	log "Installing mkinitcpio-hooks-wizard..."

	cat >"${ISO_ROOT}/usr/local/bin/mkinitcpio-hooks-wizard" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"

MODE=""           # "systemd" | "udev"
USE_LVM=""        # "y" | "n"
USE_ENCRYPT=""    # "y" | "n"
USE_MDADM=""      # "y" | "n"
USE_RESUME=""     # "y" | "n"
USE_KEYMAP=""     # "y" | "n"
USE_KMS=""        # "y" | "n"

OUT_PATH="/etc/mkinitcpio.conf"
DRY_RUN="false"

function show_with_pager() {
  local pager="${HELP_PAGER:-less -R}"
  if [[ "$pager" == "cat" ]]; then
    cat
    return 0
  fi
  local bin="${pager%% *}"
  if ! command -v "$bin" >/dev/null 2>&1; then
    cat
    return 0
  fi
  eval "$pager"
}

function usage() {
  cat <<EOF2 | show_with_pager
"$SCRIPT_NAME" - generate a mkinitcpio.conf tailored to your storage stack.

Usage:
  sudo "$SCRIPT_NAME" [OPTIONS]

If called without options, you will be interactively asked:

  * Whether to use systemd-based or udev-based initramfs
  * Whether you use:
      - LUKS encryption for root
      - LVM for root
      - mdadm RAID for root (mdadm_udev)
      - swap/resume
      - non-US keymap / consolefont in early userspace
      - kms (GPU modesetting) in initramfs

Options (non-interactive):

  --systemd           Use systemd initramfs hooks
  --udev              Use traditional udev hooks

  --lvm / --no-lvm
  --encrypt / --no-encrypt
  --mdadm / --no-mdadm
  --resume / --no-resume
  --keymap / --no-keymap
  --kms / --no-kms

  -o, --output PATH   Target mkinitcpio.conf (default: /etc/mkinitcpio.conf)
  --dry-run           Print config to stdout; do not write

After generating, rebuild:
  sudo mkinitcpio -P

EOF2
}

function ensure_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: ${SCRIPT_NAME} must be run as root." >&2
    exit 1
  fi
}

function ask_bool() {
  local var_name="$1"
  local prompt="$2"
  local default="$3"
  local current="${!var_name:-}"

  if [[ -n "$current" ]]; then
    return 0
  fi

  local suffix="[y/N]"
  [[ "$default" == "y" ]] && suffix="[Y/n]"

  local answer
  while true; do
    read -r -p "${prompt} ${suffix} " answer || answer=""
    answer="${answer,,}"
    if [[ -z "$answer" ]]; then
      answer="$default"
    fi
    case "$answer" in
      y|yes)
        printf -v "$var_name" "y"
        return 0
        ;;
      n|no)
        printf -v "$var_name" "n"
        return 0
        ;;
    esac
    echo "Please answer y or n."
  done
}

function ask_mode() {
  if [[ -n "$MODE" ]]; then
    return 0
  fi

  echo "Select initramfs style:"
  echo "  1) systemd"
  echo "  2) udev"
  local answer
  while true; do
    read -r -p "Choice [1/2, default=1]: " answer || answer=""
    case "$answer" in
      ""|1)
        MODE="systemd"
        return 0
        ;;
      2)
        MODE="udev"
        return 0
        ;;
    esac
    echo "Please enter 1 or 2."
  done
}

function parse_args() {
  while (($#)); do
    case "$1" in
      --systemd)    MODE="systemd"; shift ;;
      --udev)       MODE="udev"; shift ;;
      --lvm)        USE_LVM="y"; shift ;;
      --no-lvm)     USE_LVM="n"; shift ;;
      --encrypt)    USE_ENCRYPT="y"; shift ;;
      --no-encrypt) USE_ENCRYPT="n"; shift ;;
      --mdadm)      USE_MDADM="y"; shift ;;
      --no-mdadm)   USE_MDADM="n"; shift ;;
      --resume)     USE_RESUME="y"; shift ;;
      --no-resume)  USE_RESUME="n"; shift ;;
      --keymap)     USE_KEYMAP="y"; shift ;;
      --no-keymap)  USE_KEYMAP="n"; shift ;;
      --kms)        USE_KMS="y"; shift ;;
      --no-kms)     USE_KMS="n"; shift ;;
      -o|--output)  OUT_PATH="$2"; shift 2 ;;
      --dry-run)    DRY_RUN="true"; shift ;;
      -h|--help)    usage; exit 0 ;;
      *)            echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
  done
}

function build_hooks() {
  local hooks=()

  if [[ "$MODE" == "systemd" ]]; then
    hooks+=(base systemd autodetect microcode modconf)
    if [[ "$USE_KMS" == "y" ]]; then
      hooks+=(kms)
    fi
    if [[ "$USE_KEYMAP" == "y" ]]; then
      hooks+=(keyboard sd-vconsole)
    fi
    hooks+=(block)
    if [[ "$USE_MDADM" == "y" ]]; then
      hooks+=(mdadm_udev)
    fi
    if [[ "$USE_ENCRYPT" == "y" ]]; then
      hooks+=(sd-encrypt)
    fi
    if [[ "$USE_LVM" == "y" ]]; then
      hooks+=(lvm2)
    fi
    if [[ "$USE_RESUME" == "y" ]]; then
      hooks+=(sd-resume)
    fi
    hooks+=(filesystems fsck sd-shutdown)
  else
    hooks+=(base udev autodetect microcode modconf)
    if [[ "$USE_KEYMAP" == "y" ]]; then
      hooks+=(keyboard keymap consolefont)
    fi
    hooks+=(block)
    if [[ "$USE_MDADM" == "y" ]]; then
      hooks+=(mdadm_udev)
    fi
    if [[ "$USE_ENCRYPT" == "y" ]]; then
      hooks+=(encrypt)
    fi
    if [[ "$USE_LVM" == "y" ]]; then
      hooks+=(lvm2)
    fi
    if [[ "$USE_RESUME" == "y" ]]; then
      hooks+=(resume)
    fi
    hooks+=(filesystems fsck)
  fi

  HOOKS_LINE="HOOKS=(${hooks[*]})"
}

function write_config() {
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"

  local content
  content=$(cat <<EOF2
# vim:set ft=sh
# mkinitcpio configuration generated by ${SCRIPT_NAME}

MODULES=()
BINARIES=()
FILES=()

${HOOKS_LINE}

COMPRESSION="zstd"
COMPRESSION_OPTIONS=("--fast")
EOF2
)

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "$content"
    return 0
  fi

  if [[ -f "$OUT_PATH" ]]; then
    local backup="${OUT_PATH}.bak-${ts}"
    echo "Backing up existing ${OUT_PATH} -> ${backup}"
    cp -a "$OUT_PATH" "$backup"
  fi

  echo "Writing new mkinitcpio configuration to ${OUT_PATH}"
  printf '%s\n' "$content" >"$OUT_PATH"
  echo "Remember to rebuild:
  sudo mkinitcpio -P"
}

# function build-custom-bashrc() {
# 	local 
# }

function main() {
  ensure_root
  parse_args "$@"

  ask_mode
  ask_bool USE_LVM     "Use LVM for root (lvm2)?"           "y"
  ask_bool USE_ENCRYPT "Root is LUKS-encrypted?"            "y"
  ask_bool USE_MDADM   "Root uses mdadm RAID (mdadm_udev)?" "n"
  ask_bool USE_RESUME  "Enable resume hook (swap/hibern.)?" "n"
  ask_bool USE_KEYMAP  "Non-US keymap in early userspace?"  "y"
  ask_bool USE_KMS     "Add kms hook (early GPU modeset)?"  "n"

  echo
  echo "Summary:"
  echo "  MODE        = ${MODE}"
  echo "  LVM         = ${USE_LVM}"
  echo "  ENCRYPT     = ${USE_ENCRYPT}"
  echo "  MDADM_RAID  = ${USE_MDADM}"
  echo "  RESUME      = ${USE_RESUME}"
  echo "  KEYMAP      = ${USE_KEYMAP}"
  echo "  KMS         = ${USE_KMS}"
  echo

  build_hooks
  echo "Generated:"
  echo "  ${HOOKS_LINE}"
  echo

  write_config
}

main "$@"
EOF

	chmod 755 "${ISO_ROOT}/usr/local/bin/mkinitcpio-hooks-wizard"
}

#-------------------------------------------------------------------------------
# Install install-bashrc.example (from host or fallback template)
#-------------------------------------------------------------------------------
function install_bashrc_template() {
	log "Installing install-bashrc.example..."

	mkdir -p "${ISO_ROOT}/root"

	if [[ -f "/root/customize_airootfs.sh" ]]; then
		cp "/root/customize_airootfs.sh" "${ISO_ROOT}/root/customize_airootfs.sh"
		return 0
	else
		cat > "${ISO_ROOT}/root/customize_airootfs.sh" <<'EOF'
		#!/usr/bin/env bash
		set -euo pipefail

		# Initialize pacman keyring in the live system

		if ! pacman-key --list-keys >/dev/null 2>&1; then
			pacman-key --init
			pacman-key --populate archlinux
		fi
		
		# Add archzfs key if not present
		
		if ! pacman-key --list-keys DDF7DB817396A49B2A2723F7403BD972F75D9D76 \
			>/dev/null 2>&1; then
		pacman-key --recv-keys DDF7DB817396A49B2A2723F7403BD972F75D9D76 \
			|| pacman-key --keyserver hkps://keyserver.ubuntu.com \
			--recv-keys DDF7DB817396A49B2A2723F7403BD972F75D9D76
		pacman-key --lsign-key DDF7DB817396A49B2A2723F7403BD972F75D9D76
		fi
		EOF
	fi

	local custom-bashrc=/root/custom.bashrc
	zmodload zsh/system
	local ERRNO=0
	if [ ! -f "$custom-bashrc" ]; then
		err=$ERRNO

		case $errnos[err] in
			("") echo exists, not a regular file
				;;
			(ENOENT|ENOTDIR)
				if [ -L "$custom-bashrc" ]; then
					echo broken link
				else
					echo does not exist
				fi
				;;
			(*) syserror -p "can't tell: " "$err"
		esac
	fi




	if [[ -f "/root/.bashrc" ]]; then
		cp 

		cp "/root/.bashrc" "${ISO_ROOT}/root/install-bashrc.example"
		return 0
	fi

	cat >"${ISO_ROOT}/root/install-bashrc.example" <<'EOF'
# .bashrc template for new user "heini"

# Aliases
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

# Prompt
PS1='[\u@\h \W]\$ '

function clone_repos() {
  mkdir -p "$HOME/repos"
  cd "$HOME/repos" || exit 1
  echo "clone_repos(): override this in your own .bashrc."
}
EOF
}

#-------------------------------------------------------------------------------
# Install setup-heini script (intended for installed system)
#-------------------------------------------------------------------------------
function install_setup_heini_script() {
	log "Installing setup-heini helper..."

	cat >"${ISO_ROOT}/usr/local/bin/setup-heini" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: setup-heini must be run as root." >&2
  exit 1
fi

DEFAULT_USER="heini"

read -r -p "Enter username to create [${DEFAULT_USER}]: " NEW_USER
NEW_USER="${NEW_USER:-$DEFAULT_USER}"

if id "${NEW_USER}" &>/dev/null; then
  echo "User ${NEW_USER} already exists; skipping creation."
else
  echo "==> Creating user ${NEW_USER}..."
  useradd -m -s /bin/bash -G wheel,storage,power,video,audio,input \
    "${NEW_USER}"
  echo "Set password for ${NEW_USER}:"
  passwd "${NEW_USER}"
fi

echo "Set password for root (if desired):"
passwd || true

HOME_DIR="/home/${NEW_USER}"
mkdir -p "${HOME_DIR}"

if [[ -f "/root/install-bashrc.example" ]]; then
  if [[ -f "${HOME_DIR}/.bashrc" ]]; then
    mv "${HOME_DIR}/.bashrc" "${HOME_DIR}/.bashrc.skel"
    echo "Backed up existing ${HOME_DIR}/.bashrc -> .bashrc.skel"
  fi
  cp "/root/install-bashrc.example" "${HOME_DIR}/.bashrc"
  chown "${NEW_USER}:${NEW_USER}" "${HOME_DIR}/.bashrc"
  echo "Installed /root/install-bashrc.example -> ${HOME_DIR}/.bashrc"
else
  echo "WARNING: /root/install-bashrc.example not found; leaving .bashrc \
untouched."
fi

install -d -m 755 -o "${NEW_USER}" -g "${NEW_USER}" \
  "${HOME_DIR}/bin" "${HOME_DIR}/bin/bin" "${HOME_DIR}/repos"

echo "Created ${HOME_DIR}/bin/bin and ${HOME_DIR}/repos."

echo
read -r -p "Run post-setup bootstrap now \
(enable-chaotic-aur, new-mirrors, pacman -Syy, clone_repos)? [y/N]: " and
and="${and,,}"

if [[ "${and}" == "y" || "${and}" == "yes" ]]; then
  echo "==> Running post-setup bootstrap..."

  if command -v enable-chaotic-aur >/dev/null 2>&1; then
    echo "  -> enable-chaotic-aur"
    enable-chaotic-aur
  else
    echo "  -> enable-chaotic-aur not found; skipping."
  fi

  if command -v new-mirrors >/dev/null 2>&1; then
    echo "  -> new-mirrors"
    new-mirrors
  else
    echo "  -> new-mirrors not found; skipping."
  fi

  echo "  -> pacman -Syy"
  pacman -Syy

  echo "  -> su - ${NEW_USER} (clone_repos via .bashrc if defined)"
  su - "${NEW_USER}" -c '
    mkdir -p "$HOME/bin/bin" "$HOME/repos"
    if [ -f "$HOME/.bashrc" ]; then
      . "$HOME/.bashrc"
    fi
    if declare -F clone_repos >/dev/null 2>&1; then
      echo "Running clone_repos()..."
      clone_repos
    else
      echo "clone_repos() not defined in ~/.bashrc; skipping."
    fi
  '
else
  echo "Skipping bootstrap step."
fi

echo
read -r -p "Switch to user \"${NEW_USER}\" now? (exec su - ${NEW_USER}) \
[y/N]: " sw
sw="${sw,,}"
if [[ "${sw}" == "y" || "${sw}" == "yes" ]]; then
  echo "Switching to ${NEW_USER}..."
  exec su - "${NEW_USER}"
fi

echo "setup-heini completed."
EOF

	chmod 755 "${ISO_ROOT}/usr/local/bin/setup-heini"
}

#-------------------------------------------------------------------------------
# post-pacstrap-setup helper:
#   - Run in live ISO after pacstrap + fstab + basic config
#   - Copies /etc configs and helper scripts into /mnt
#   - Initializes and signs Chaotic-AUR and ZFS keys in the chroot
#-------------------------------------------------------------------------------
function install_post_pacstrap_helper() {
	log "Installing post-pacstrap-setup helper..."

	cat >"${ISO_ROOT}/usr/local/bin/post-pacstrap-setup" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

function log() {
  printf '==> %s\n' "$*"
}

function ensure_mnt_root() {
  if [[ ! -d /mnt/etc ]]; then
    echo "ERROR: /mnt/etc not found. Did you run pacstrap and mount /mnt?" >&2
    exit 1
  fi
}

function copy_configs() {
  log "Copying live /etc configs into /mnt/etc..."

  install -Dm644 /etc/locale.conf /mnt/etc/locale.conf
  install -Dm644 /etc/locale.gen /mnt/etc/locale.gen
  install -Dm644 /etc/vconsole.conf /mnt/etc/vconsole.conf
  install -Dm644 /etc/pacman.conf /mnt/etc/pacman.conf
  install -Dm644 /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist

  if [[ -f /etc/pacman.d/chaotic-mirrorlist ]]; then
    install -Dm644 /etc/pacman.d/chaotic-mirrorlist \
      /mnt/etc/pacman.d/chaotic-mirrorlist
  fi

  install -Dm440 /etc/sudoers /mnt/etc/sudoers
}

function copy_helpers() {
  log "Copying helper scripts into /mnt/usr/local/bin..."
  install -Dm755 /usr/local/bin/new-mirrors \
    /mnt/usr/local/bin/new-mirrors || true
  install -Dm755 /usr/local/bin/enable-chaotic-aur \
    /mnt/usr/local/bin/enable-chaotic-aur || true
  install -Dm755 /usr/local/bin/mkinitcpio-hooks-wizard \
    /mnt/usr/local/bin/mkinitcpio-hooks-wizard || true
  install -Dm755 /usr/local/bin/setup-heini \
    /mnt/usr/local/bin/setup-heini || true
}

function setup_keys_in_chroot() {
  log "Initializing pacman-key and importing Chaotic + ZFS keys in /mnt..."

  arch-chroot /mnt /bin/bash <<'CHROOT_EOF'
set -Eeuo pipefail
IFS=$'\n\t'

pacman-key --init || true
pacman-key --populate archlinux || true

# Chaotic-AUR keys (same as enable-chaotic-aur)
pacman-key -r FBA220DFC880C036 || true
pacman-key --lsign-key FBA220DFC880C036 || true

pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com || true
pacman-key --lsign-key 3056513887B78AEB || true

# ZFS / archzfs key (harmless even if archzfs repo is unused)
pacman-key --recv-key DDF7DB817396A49B2A2723F7403BD972F75D9D76 \
  --keyserver keyserver.ubuntu.com || true
pacman-key --lsign-key DDF7DB817396A49B2A2723F7403BD972F75D9D76 || true
CHROOT_EOF
}

function main() {
  ensure_mnt_root
  copy_configs
  copy_helpers
  setup_keys_in_chroot
  log "post-pacstrap-setup finished."
  log "You can now arch-chroot /mnt and use:"
  log "  enable-chaotic-aur, mkinitcpio-hooks-wizard, setup-heini, etc."
}

main "$@"
EOF

	chmod 755 "${ISO_ROOT}/usr/local/bin/post-pacstrap-setup"
}

#-------------------------------------------------------------------------------
# Build ISO with mkarchiso
#-------------------------------------------------------------------------------
function build_iso() {
	log "Building ISO with mkarchiso..."
	mkarchiso -v -w "$WORK_DIR" -o "$ISO_OUT" "$PROFILE_DIR"
	log "ISO built in: ${ISO_OUT}"
}

#-------------------------------------------------------------------------------
# Helpers for USB burning
#-------------------------------------------------------------------------------
function find_latest_iso() {
	local iso
	iso="$(ls -1 "$ISO_OUT"/*.iso 2>/dev/null | sort | tail -n1 || true)"
	if [[ -z "$iso" ]]; then
		echo "ERROR: No ISO file found in ${ISO_OUT}" >&2
		return 1
	fi
	printf '%s\n' "$iso"
}

function list_candidate_disks() {
	echo "Candidate disks (USB marked when detectable):"
	lsblk -dpno NAME,TRAN,SIZE,MODEL,TYPE | awk '
    "$5" == "disk" {
      tag = ("$2" == "usb" ? "[USB]" : "     ");
      printf "  %s %-15s %-4s %-8s %s\n", tag, "$1", "$2", "$3", "$4"
    }'
	echo
	echo "Verify carefully before selecting a target; choosing the wrong disk"
	echo "will destroy its contents."
}

function unmount_device_partitions() {
	local dev="$1"
	local parts

	parts="$(lsblk -lnpo NAME "$dev" | tail -n +2 || true)"
	if [[ -z "$parts" ]]; then
		return 0
	fi

	echo "Unmounting any mounted partitions on ${dev}..."
	local p m
	while read -r p; do
		m="$(awk -v d="$p" '"$1"==d {print "$2"}' /proc/self/mounts | head -n1)"
		if [[ -n "$m" ]]; then
			echo "  umount ${m}"
			umount "$m"
		fi
	done <<<"$parts"
}

#-------------------------------------------------------------------------------
# Ask user whether to burn ISO to USB, then run ddrescue if confirmed
#-------------------------------------------------------------------------------
function prompt_burn_iso() {
	local and

	echo
	log "ISO build complete."
	read -r -p "Burn ISO to a USB stick now? [y/N]: " and
	and="${and,,}"
	if [[ "$and" != "y" && "$and" != "yes" ]]; then
		log "Skipping USB burning step."
		return 0
	fi

	local iso
	if ! iso="$(find_latest_iso)"; then
		return 1
	fi

	echo
	echo "ISO to be written:"
	echo "  ${iso}"
	echo
	list_candidate_disks

	local dev
	read -r -p "Enter target device path (e.g. /dev/sdX, /dev/nvme0n1): " dev

	if [[ -z "$dev" || ! -b "$dev" ]]; then
		echo "ERROR: '"$dev"' is not a valid block device." >&2
		return 1
	fi

	echo
	echo "WARNING: All data on ${dev} will be IRREVERSIBLY DESTROYED."
	read -r -p "Type 'YES' (all caps) to continue: " and
	if [[ "$and" != "YES" ]]; then
		echo "Aborted; not writing to ${dev}."
		return 1
	fi

	unmount_device_partitions "$dev"

	echo
	log "Running: ddrescue -v --force \"${iso}\" \"${dev}\""
	ddrescue -v --force "$iso" "$dev"
	sync
	echo
	log "USB write finished. You can now try booting from ${dev}."
}

#-------------------------------------------------------------------------------
# main
#-------------------------------------------------------------------------------
function main() {
	ensure_root
	parse_args "$@"

	log "Selected kernel flavor: ${KERNEL_FLAVOR} (ENABLE_ZFS=${ENABLE_ZFS})"

	require_host_packages
	prepare_profile
	configure_kernel_packages
	ensure_extra_tools
	install_core_configs
	install_pacman_conf
	install_mirrorlist
	install_new_mirrors_helper
	install_enable_chaotic_aur
	install_mkinitcpio_hooks_wizard
	install_bashrc_template
	install_setup_heini_script
	install_post_pacstrap_helper
	build_iso
	prompt_burn_iso
}

main "$@"
