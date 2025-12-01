#!/usr/bin/env bash
#===============================================================================
# custom-arch-iso.sh
#
# Build a custom Arch ISO with:
#   - Kernel selectable at build time:
#       • default: linux + linux-headers
#       • lts:     linux-lts + linux-lts-headers
#   - Extra CLI tools (fzf, lsof, strace, git, gptfdisk, bat, fd, reflector,
#     rsync, neovim, eza, lsd, python-rich, python-rapidfuzz, parted, gparted)
#   - Clean pacman.conf (core/extra/multilib, Chaotic-AUR commented out)
#   - Your current mirrorlist baked into the ISO (and forced post-pacstrap)
#   - Core configs overridden *after* pacstrap via customize_airootfs.sh:
#       • /etc/locale.conf
#       • /etc/locale.gen  (and locale-gen is run)
#       • /etc/vconsole.conf
#       • /etc/sudoers
#       • /etc/pacman.d/mirrorlist
#   - Helper scripts in the live environment:
#       * new-mirrors
#       * enable-chaotic-aur
#       * mkinitcpio-hooks-wizard
#       * setup-heini
#       * install-bashrc.example template
#
# Kernel selection:
#   No arg           → linux + linux-headers
#   lts / --lts      → linux-lts + linux-lts-headers
#   -k / --kernel    → linux | linux-lts
#
# After ISO build, you are offered to burn it to USB via ddrescue.
#===============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

BUILDROOT="${HOME}/ISOBUILD/custom-arch-iso"
PROFILE_SRC="/usr/share/archiso/configs/releng"
PROFILE_DIR="$BUILDROOT"
WORK_DIR="${PROFILE_DIR}/WORK"
ISO_OUT="${PROFILE_DIR}/ISOOUT"
ISO_ROOT="${PROFILE_DIR}/airootfs"

KERNEL_CHOICE="linux" # "linux" or "linux-lts"

#-------------------------------------------------------------------------------
# Logging helper
#-------------------------------------------------------------------------------
function log() {
	printf '==> %s\n' "$*"
}

#-------------------------------------------------------------------------------
# Usage / argument parsing
#-------------------------------------------------------------------------------
function usage() {
	cat <<EOF
usage: $(basename "$0") [lts | --lts | -k <kernel> | --kernel <kernel>]

Kernel selection (for the live ISO):

  (no argument)      Use 'linux' (standard kernel) and 'linux-headers'.
  lts, --lts         Use 'linux-lts' and 'linux-lts-headers'.
  -k, --kernel K     Explicit kernel; K must be 'linux' or 'linux-lts'.

Examples:
  sudo $(basename "$0")
  sudo $(basename "$0") lts
  sudo $(basename "$0") --lts
  sudo $(basename "$0") -k linux-lts
EOF
}

function parse_args() {
	while (($#)); do
		case "$1" in
		lts | linux-lts)
			KERNEL_CHOICE="linux-lts"
			shift
			;;
		linux)
			KERNEL_CHOICE="linux"
			shift
			;;
		--lts)
			KERNEL_CHOICE="linux-lts"
			shift
			;;
		-k | --kernel)
			if (($# < 2)); then
				echo "ERROR: --kernel requires an argument (linux|linux-lts)." >&2
				usage
				exit 1
			fi
			case "$2" in
			linux)
				KERNEL_CHOICE="linux"
				;;
			linux-lts | lts)
				KERNEL_CHOICE="linux-lts"
				;;
			*)
				echo "ERROR: Unsupported kernel '$2' (use 'linux' or 'linux-lts')." \
					>&2
				usage
				exit 1
				;;
			esac
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			echo "ERROR: Unknown argument '$1'." >&2
			usage
			exit 1
			;;
		esac
	done
}

#-------------------------------------------------------------------------------
# Require running as root
#-------------------------------------------------------------------------------
function ensure_root() {
	if [[ "$EUID" -ne 0 ]]; then
		printf 'ERROR: Run this script as root (e.g. sudo %s)\n' \
			"$(basename "$0")" >&2
		exit 1
	fi
}

#-------------------------------------------------------------------------------
# Host sanity checks
#-------------------------------------------------------------------------------
function require_host_packages() {
	local pkgs=(archiso ddrescue reflector rsync curl)
	local missing=()

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
# Prepare releng profile copy
#-------------------------------------------------------------------------------
function prepare_profile() {
	log "Copying releng profile to ${PROFILE_DIR}..."
	rm -rf "$PROFILE_DIR"
	mkdir -p "$PROFILE_DIR"
	cp -a "${PROFILE_SRC}/." "${PROFILE_DIR}/"
	mkdir -p "$WORK_DIR" "$ISO_OUT"
	mkdir -p "${ISO_ROOT}/usr/local/bin"
}

#-------------------------------------------------------------------------------
# Kernel selection inside packages.x86_64
#-------------------------------------------------------------------------------
function configure_kernel_packages() {
	local kernel="$1"
	local pkg_file="${PROFILE_DIR}/packages.x86_64"

	log "Configuring kernel packages in packages.x86_64 (${kernel})..."

	if [[ ! -f "$pkg_file" ]]; then
		echo "ERROR: ${pkg_file} not found." >&2
		exit 1
	fi

	# Remove unwanted kernel variants explicitly (linux vs linux-lts).
	case "$kernel" in
	linux)
		sed -i -E '/^linux-lts(-headers)?$/d' "$pkg_file"
		;;
	linux-lts)
		sed -i -E '/^linux(-headers)?$/d' "$pkg_file"
		;;
	esac

	local k_pkg="$kernel"
	local h_pkg

	if [[ "$kernel" == "linux" ]]; then
		h_pkg="linux-headers"
	else
		h_pkg="${kernel}-headers" # linux-lts-headers
	fi

	local p
	for p in "$k_pkg" "$h_pkg"; do
		if ! grep -qE "^[[:space:]]*${p}(\s|$)" "$pkg_file"; then
			printf '  + %s (kernel)\n' "$p"
			echo "$p" >>"$pkg_file"
		else
			printf '  = %s (kernel already listed)\n' "$p"
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
		if ! grep -qE "^[[:space:]]*${p}(\s|$)" "$pkg_file"; then
			printf '  + %s\n' "$p"
			echo "$p" >>"$pkg_file"
		else
			printf '  = %s (already listed)\n' "$p"
		fi
	done
}

#-------------------------------------------------------------------------------
# Install cleaned pacman.conf (Chaotic-AUR commented)
#-------------------------------------------------------------------------------
function install_pacman_conf() {
	log "Installing cleaned pacman.conf (core/extra/multilib + Chaotic-AUR \
commented)..."

	cat >"${PROFILE_DIR}/pacman.conf" <<'EOF'
[options]
HoldPkg      = pacman glibc
Architecture = auto
CheckSpace
SigLevel          = Required DatabaseOptional
LocalFileSigLevel = Required

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
}

#-------------------------------------------------------------------------------
# Core config templates under /root/custom-configs (applied post-pacstrap)
#-------------------------------------------------------------------------------
function install_core_config_templates() {
	log "Installing core config templates under /root/custom-configs..."

	local cfg_dir="${ISO_ROOT}/root/custom-configs"
	mkdir -p "$cfg_dir"

	# locale.conf
	cat >"${cfg_dir}/locale.conf" <<'EOF'
LANG=en_DK.UTF-8
LC_COLLATE=C
LC_TIME=en_DK.UTF-8
LC_NUMERIC=en_DK.UTF-8
LC_MONETARY=en_DK.UTF-8
LC_PAPER=en_DK.UTF-8
LC_MEASUREMENT=en_DK.UTF-8
EOF

	# locale.gen (minimal)
	cat >"${cfg_dir}/locale.gen" <<'EOF'
# Minimal locale.gen for custom ISO
en_DK.UTF-8 UTF-8
EOF

	# vconsole.conf
	cat >"${cfg_dir}/vconsole.conf" <<'EOF'
XKBLAYOUT=dk
KEYMAP=dk-latin1
EOF

	# sudoers
	cat >"${cfg_dir}/sudoers" <<'EOF'
## sudoers file (custom ISO template)

Defaults!/usr/bin/visudo env_keep += "SUDO_EDITOR EDITOR VISUAL"
Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/bin"

root  ALL=(ALL:ALL) ALL
%wheel ALL=(ALL:ALL) ALL

@includedir /etc/sudoers.d
EOF
}

#-------------------------------------------------------------------------------
# Copy current mirrorlist into ISO and template dir
#-------------------------------------------------------------------------------
function install_mirrorlist() {
	log "Copying current system mirrorlist to ISO..."

	if [[ ! -f /etc/pacman.d/mirrorlist ]]; then
		echo "WARNING: /etc/pacman.d/mirrorlist not found on host." >&2
		return 0
	fi

	mkdir -p "${ISO_ROOT}/etc/pacman.d"
	cp /etc/pacman.d/mirrorlist "${ISO_ROOT}/etc/pacman.d/mirrorlist"

	# Also keep a copy under /root/custom-configs so customize_airootfs.sh
	# can overwrite /etc/pacman.d/mirrorlist after pacstrap.
	local cfg_dir="${ISO_ROOT}/root/custom-configs"
	mkdir -p "$cfg_dir"
	cp /etc/pacman.d/mirrorlist "${cfg_dir}/mirrorlist"
}

#-------------------------------------------------------------------------------
# Append / create post-pacstrap overrides in customize_airootfs.sh
#   - This script runs inside the airootfs chroot *after* pacstrap.
#-------------------------------------------------------------------------------
function append_customize_airootfs_snippet() {
  local script="${ISO_ROOT}/root/customize_airootfs.sh"

  # If the releng profile does not provide customize_airootfs.sh, create a
  # minimal one so archiso will execute it.
  if [[ ! -f "$script" ]]; then
    log "customize_airootfs.sh not found; creating a minimal one..."
    mkdir -p "$(dirname "$script")"
    cat >"$script" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# customize_airootfs.sh
# This script is executed inside the airootfs chroot after pacstrap.
# Custom overrides appended by external tools will follow below.
EOF
    chmod 755 "$script"
  else
    log "Found existing customize_airootfs.sh; appending overrides..."
  fi

  # Now append our config override block (idempotent in effect; if you re-run
  # the build from a clean BUILDROOT, this is written once per build).
  cat <<'EOF' >>"$script"

# ---------------------------------------------------------------------------
# Custom config overrides injected by custom-arch-iso.sh
# This runs inside the airootfs chroot AFTER pacstrap.
# ---------------------------------------------------------------------------

if [[ -d /root/custom-configs ]]; then
  if [[ -f /root/custom-configs/locale.conf ]]; then
    install -Dm644 /root/custom-configs/locale.conf /etc/locale.conf
  fi

  if [[ -f /root/custom-configs/locale.gen ]]; then
    install -Dm644 /root/custom-configs/locale.gen /etc/locale.gen
    locale-gen || true
  fi

  if [[ -f /root/custom-configs/vconsole.conf ]]; then
    install -Dm644 /root/custom-configs/vconsole.conf /etc/vconsole.conf
  fi

  if [[ -f /root/custom-configs/sudoers ]]; then
    install -Dm440 /root/custom-configs/sudoers /etc/sudoers
  fi

  if [[ -f /root/custom-configs/mirrorlist ]]; then
    install -Dm644 /root/custom-configs/mirrorlist /etc/pacman.d/mirrorlist
  fi
fi

# ---------------------------------------------------------------------------
# End of custom config overrides
# ---------------------------------------------------------------------------

EOF
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
# Install enable-chaotic-aur helper into ISO (for *post-install* use)
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
pacman-key --lsign-key FBA220DFC880C036

# Pedro Henrique Lara Campos
pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com || true
pacman-key --lsign-key 3056513887B78AEB

echo "==> Installing chaotic-keyring and chaotic-mirrorlist..."
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

echo "Chaotic-AUR is enabled."
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
  printf '%s\n' "$content" > "$OUT_PATH"
  echo "Remember to rebuild:
  sudo mkinitcpio -P"
}

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

	if [[ -f "${HOME}/.bashrc" ]]; then
		cp "${HOME}/.bashrc" "${ISO_ROOT}/root/install-bashrc.example"
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
# Install setup-heini script
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
passwd

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
    $5 == "disk" {
      tag = ($2 == "usb" ? "[USB]" : "     ");
      # NAME, TRAN, SIZE, MODEL (may have spaces)
      printf "  %s %-15s %-4s %-8s %s\n", tag, $1, $2, $3, $4
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
		m="$(awk -v d="$p" '$1==d {print $2}' /proc/self/mounts | head -n1)"
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
		echo "ERROR: '${dev}' is not a valid block device." >&2
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
	parse_args "$@"
	ensure_root
	require_host_packages
	prepare_profile
	configure_kernel_packages "$KERNEL_CHOICE"
	ensure_extra_tools
	install_pacman_conf
	install_core_config_templates
	install_mirrorlist
	install_new_mirrors_helper
	install_enable_chaotic_aur
	install_mkinitcpio_hooks_wizard
	install_bashrc_template
	install_setup_heini_script
	append_customize_airootfs_snippet
	build_iso
	prompt_burn_iso
}

main "$@"
