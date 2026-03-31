#!/usr/bin/env bash

set -euo pipefail

#-------------------------------------------------------------------------------
# archiso-tool.sh
#
# Fresh-state Arch ISO builder and burner.
#
# Design goals:
#   - never keep the editable profile copy inside mkarchiso's work directory
#   - every build starts from a fresh copied releng profile
#   - overlay works predictably
#   - burn step supports fzf + pv or ddrescue
#-------------------------------------------------------------------------------

function show_help() {
  cat <<'EOF_HELP'
archiso-tool.sh

Subcommands:
  build         Build a custom Arch ISO from releng.
  burn          Burn an ISO to a USB device.
  build-burn    Build first, then burn the newest matching ISO.
  clean         Remove managed state safely.
  list-isos     List ISO files that the burn picker would see.
  list-disks    List whole-disk burn targets.

General notes:
  - Build state is kept under a separate state root.
  - Each build recreates a fresh profile copy and a fresh work tree.
  - Therefore, there is no --clean flag for build; clean-by-default is built in.
  - Overlay precedence is:
      releng base < overlay < explicit CLI customizations < scripts-dir/root key
  - Burn always writes to a whole disk, never to a partition.

Usage:
  sudo ./archiso-tool.sh <subcommand> [options]

Build options:
  --profile-name NAME         Managed profile name. Default: heini.
  --iso-name NAME             Resulting ISO name stem.
  --iso-label LABEL           ISO9660 volume label.
  --iso-version VERSION       ISO version string.
  --install-dir NAME          install_dir inside the ISO. Max 8 [a-z0-9].
  --state-root DIR            Managed state root.
  --outdir DIR                Output directory for built artifacts.
  --overlay DIR               Copy this directory into airootfs/.
  --scripts-dir DIR           Copy files into airootfs/usr/local/bin/.
  --packages-file FILE        Extra packages, one per line.
  --pkg NAME                  Add one extra package. Repeatable.
  --with-bios                 Add BIOS boot via syslinux.
  --hostname NAME             Write /etc/hostname into the live ISO.
  --locale LOCALE             Write /etc/locale.conf into the live ISO.
  --keymap KEYMAP             Write /etc/vconsole.conf into the live ISO.
  --timezone TZ               Write /etc/localtime symlink in the live ISO.
  --enable-sshd               Enable sshd in the live ISO.
  --root-authorized-keys FILE Install as /root/.ssh/authorized_keys.
  --prune-work                Let mkarchiso delete the work tree after success.

Burn options:
  --iso FILE                  ISO file to burn.
  --search-dir DIR            Search directory for ISO picker.
  --device DEV                Target whole-disk device, e.g. /dev/sdb.
  --method METHOD             auto, pv, ddrescue. Default: auto.
  --include-system-disk       Allow the current system disk in picker.
  --eject                     Try to eject after write.

Clean options:
  --profile-name NAME         Managed profile name. Default: heini.
  --iso-name NAME             ISO stem to purge from outdir.
  --state-root DIR            Managed state root.
  --outdir DIR                Output directory.
  --all                       Remove all managed profiles from state root.
  --purge-outdir              Also delete matching ISO artifacts from outdir.
  --yes                       Do not ask for confirmation.

Examples:
  sudo ./archiso-tool.sh build \
    --profile-name heini \
    --overlay ./overlay \
    --scripts-dir ./scripts \
    --packages-file ./packages.live \
    --outdir ./out

  sudo ./archiso-tool.sh build --with-bios --enable-sshd \
    --root-authorized-keys ~/.ssh/id_ed25519.pub

  sudo ./archiso-tool.sh burn --search-dir ./out

  sudo ./archiso-tool.sh build-burn \
    --overlay ./overlay --scripts-dir ./scripts --outdir ./out

  sudo ./archiso-tool.sh clean --profile-name heini
EOF_HELP
}

function log() {
  printf '[+] %s\n' "$*"
}

function warn() {
  printf '[!] %s\n' "$*" >&2
}

function die() {
  printf '[x] %s\n' "$*" >&2
  exit 1
}

function need_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Missing command: ${cmd}"
}

function has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

function ensure_root() {
  [[ ${EUID} -eq 0 ]] || die 'Run this script as root.'
}

function abs_path() {
  realpath -m "$1"
}

function sanitize_name() {
  local s="$1"
  s="${s,,}"
  s="${s//[^a-z0-9._-]/-}"
  s="${s#-}"
  s="${s%-}"
  printf '%s\n' "${s:-heini}"
}

function sanitize_install_dir() {
  local s="$1"
  s="${s,,}"
  s="${s//[^a-z0-9]/}"
  s="${s:0:8}"
  printf '%s\n' "${s:-archiso}"
}

function sanitize_label() {
  local s="$1"
  s="${s^^}"
  s="${s//[^A-Z0-9_]/_}"
  s="${s:0:32}"
  s="${s##_}"
  s="${s%%_}"
  printf '%s\n' "${s:-ARCHISO}"
}

function escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

function set_shell_var() {
  local file="$1"
  local var="$2"
  local value="$3"
  local escaped=''

  escaped="$(escape_sed_replacement "$value")"

  if grep -Eq "^[[:space:]]*${var}=" "$file"; then
    sed -i -E "s|^[[:space:]]*${var}=.*$|${var}=\"${escaped}\"|" "$file"
  else
    printf '%s="%s"\n' "$var" "$value" >> "$file"
  fi
}

function set_shell_array() {
  local file="$1"
  local var="$2"
  shift 2
  local joined=''
  local item=''

  for item in "$@"; do
    joined+="'${item}' "
  done
  joined="${joined% }"

  if grep -Eq "^[[:space:]]*${var}=\(" "$file"; then
    sed -i -E \
      "s|^[[:space:]]*${var}=\(.*\)$|${var}=(${joined})|" \
      "$file"
  else
    printf '%s=(%s)\n' "$var" "$joined" >> "$file"
  fi
}

function path_contains() {
  local base=''
  local cand=''

  base="$(abs_path "$1")"
  cand="$(abs_path "$2")"

  [[ "$cand" == "$base" || "$cand" == "$base"/* ]]
}

function ensure_safe_layout() {
  local state_root="$1"
  local profile_src="$2"
  local work_dir="$3"
  local out_dir="$4"

  if path_contains "$work_dir" "$profile_src" || \
     path_contains "$profile_src" "$work_dir"; then
    die 'profile_src and work_dir must not overlap.'
  fi

  if path_contains "$profile_src" "$out_dir" || \
     path_contains "$work_dir" "$out_dir"; then
    die 'outdir must not live inside profile_src or work_dir.'
  fi

  if path_contains "$out_dir" "$profile_src" || \
     path_contains "$out_dir" "$work_dir"; then
    die 'profile_src/work_dir must not live inside outdir.'
  fi

  install -d -m 0755 "$state_root" "$out_dir"
}

function ask_yes_no() {
  local prompt="$1"
  local answer=''

  printf '%s [y/N]: ' "$prompt"
  read -r answer
  [[ "${answer,,}" == 'y' || "${answer,,}" == 'yes' ]]
}

function find_packages_file() {
  local profile_dir="$1"
  local arch=''

  arch="$(uname -m)"

  if [[ -f "${profile_dir}/packages.${arch}" ]]; then
    printf '%s\n' "${profile_dir}/packages.${arch}"
    return 0
  fi

  if [[ -f "${profile_dir}/packages.x86_64" ]]; then
    printf '%s\n' "${profile_dir}/packages.x86_64"
    return 0
  fi

  if [[ -f "${profile_dir}/packages" ]]; then
    printf '%s\n' "${profile_dir}/packages"
    return 0
  fi

  die "Could not find packages file in ${profile_dir}"
}

function append_unique_packages() {
  local packages_dst="$1"
  shift
  local tmp=''
  local item=''

  tmp="$(mktemp)"
  cat "$packages_dst" > "$tmp"

  for item in "$@"; do
    [[ -n "${item// }" ]] || continue
    printf '%s\n' "$item" >> "$tmp"
  done

  awk 'NF && $1 !~ /^#/' "$tmp" | sort -u > "$packages_dst"
  rm -f "$tmp"
}

function copy_scripts_dir() {
  local src="$1"
  local dst="$2"

  [[ -d "$src" ]] || die "Scripts directory not found: ${src}"

  install -d -m 0755 "$dst"
  rsync -a --delete --exclude '.git/' --exclude '.gitignore' \
    "$src"/ "$dst"/
  find "$dst" -type f -exec chmod 0755 {} +
}

function enable_service_in_airootfs() {
  local airootfs="$1"
  local unit="$2"
  local wants_dir=''

  wants_dir="${airootfs}/etc/systemd/system/multi-user.target.wants"
  install -d -m 0755 "$wants_dir"
  ln -snf "/usr/lib/systemd/system/${unit}" "${wants_dir}/${unit}"
}

function install_root_ssh_key() {
  local pubkey_file="$1"
  local airootfs="$2"

  [[ -f "$pubkey_file" ]] || die "Key file not found: ${pubkey_file}"

  install -d -m 0700 "${airootfs}/root/.ssh"
  install -m 0600 "$pubkey_file" \
    "${airootfs}/root/.ssh/authorized_keys"

  install -d -m 0755 "${airootfs}/etc/ssh/sshd_config.d"
  cat > "${airootfs}/etc/ssh/sshd_config.d/10-root-key-only.conf" <<'EOF_SSH'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF_SSH
}

function human_size() {
  local bytes="$1"

  if has_cmd numfmt; then
    numfmt --to=iec-i --suffix=B "$bytes"
  else
    printf '%s B\n' "$bytes"
  fi
}

function kv_get() {
  local line="$1"
  local key="$2"
  sed -nE "s/.*${key}=\"([^\"]*)\".*/\1/p" <<< "$line"
}

function get_root_disk() {
  local root_source=''
  local parent=''

  root_source="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  [[ -n "$root_source" ]] || return 0

  parent="$(lsblk -no PKNAME "$root_source" 2>/dev/null || true)"
  [[ -n "$parent" ]] || return 0

  printf '/dev/%s\n' "$parent"
}

function stable_device_path() {
  local dev="$1"
  local link=''
  local target=''

  shopt -s nullglob

  for link in /dev/disk/by-id/*; do
    [[ "$link" == *-part* ]] && continue
    target="$(readlink -f "$link" 2>/dev/null || true)"
    if [[ "$target" == "$dev" ]]; then
      printf '%s\n' "$link"
      shopt -u nullglob
      return 0
    fi
  done

  shopt -u nullglob
  printf '%s\n' "$dev"
}

function list_iso_candidates() {
  local search_dir="$1"
  local file=''
  local mtime=''
  local stamp=''
  local size=''

  [[ -d "$search_dir" ]] || die "Search directory not found: ${search_dir}"

  while IFS= read -r -d '' file; do
    mtime="$(stat -c '%Y' "$file")"
    stamp="$(stat -c '%y' "$file" | cut -d'.' -f1)"
    size="$(human_size "$(stat -c '%s' "$file")")"
    printf '%s\t%s\t%s\t%s\n' "$mtime" "$stamp" "$size" "$file"
  done < <(find "$search_dir" -type f -name '*.iso' -print0)
}

function choose_iso() {
  local search_dir="$1"
  local selected=''

  has_cmd fzf || die 'fzf is required for interactive ISO selection.'

  selected="$({
    list_iso_candidates "$search_dir" \
      | sort -r -n -k1,1 \
      | cut -f2-
  } | fzf \
        --delimiter=$'\t' \
        --with-nth=1,2,3 \
        --prompt='ISO > ' \
        --header='Choose ISO file' \
        --preview '
          iso=$(printf "%s\n" {} | cut -f3-)
          printf "Path: %s\n\n" "$iso"
          ls -lh "$iso"
        ')"

  [[ -n "$selected" ]] || die 'No ISO selected.'
  printf '%s\n' "$(printf '%s\n' "$selected" | cut -f3-)"
}

function list_device_candidates() {
  local include_system_disk="$1"
  local root_disk=''
  local line=''
  local name=''
  local size=''
  local tran=''
  local rm=''
  local vendor=''
  local model=''
  local type=''

  root_disk="$(get_root_disk)"

  while IFS= read -r line; do
    name="$(kv_get "$line" NAME)"
    size="$(kv_get "$line" SIZE)"
    tran="$(kv_get "$line" TRAN)"
    rm="$(kv_get "$line" RM)"
    vendor="$(kv_get "$line" VENDOR)"
    model="$(kv_get "$line" MODEL)"
    type="$(kv_get "$line" TYPE)"

    [[ "$type" == 'disk' ]] || continue

    if [[ "$include_system_disk" == '0' ]] && [[ -n "$root_disk" ]]; then
      [[ "$name" == "$root_disk" ]] && continue
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$name" "${size:-?}" "${tran:-?}" "${rm:-?}" \
      "${vendor:-?}" "${model:-?}"
  done < <(lsblk -dpPno NAME,SIZE,TRAN,RM,VENDOR,MODEL,TYPE)
}

function choose_device() {
  local include_system_disk="$1"
  local selected=''

  has_cmd fzf || die 'fzf is required for interactive device selection.'

  selected="$(list_device_candidates "$include_system_disk" | fzf \
    --delimiter=$'\t' \
    --with-nth=1,2,3,4,5,6 \
    --prompt='DISK > ' \
    --header='Choose target whole disk' \
    --preview '
      dev=$(printf "%s\n" {} | cut -f1)
      lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS,MODEL,VENDOR,TRAN,RM \
        "$dev"
    ')"

  [[ -n "$selected" ]] || die 'No device selected.'
  printf '%s\n' "$(printf '%s\n' "$selected" | cut -f1)"
}

function ensure_whole_disk() {
  local dev="$1"
  local type=''

  [[ -b "$dev" ]] || die "Not a block device: ${dev}"
  type="$(lsblk -dn -o TYPE "$dev" 2>/dev/null || true)"
  [[ "$type" == 'disk' ]] || die "Target must be a whole disk: ${dev}"
}

function ensure_iso_fits() {
  local iso="$1"
  local dev="$2"
  local iso_size=''
  local dev_size=''

  iso_size="$(stat -c '%s' "$iso")"
  dev_size="$(blockdev --getsize64 "$dev")"

  (( iso_size <= dev_size )) || die \
    "ISO ($(human_size "$iso_size")) is larger than target \
($(human_size "$dev_size"))."
}

function disable_swap_on_device() {
  local dev="$1"
  local node=''

  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    if swapon --noheadings --show=NAME 2>/dev/null | grep -Fxq "$node"; then
      log "Disabling swap on ${node}"
      swapoff "$node"
    fi
  done < <(lsblk -lnpo NAME "$dev" | tail -n +2)
}

function unmount_device_tree() {
  local dev="$1"
  local node=''

  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    if findmnt -rn "$node" >/dev/null 2>&1; then
      log "Unmounting ${node}"
      umount "$node"
    fi
  done < <(lsblk -lnpo NAME "$dev" | tail -n +2)
}

function confirm_burn_target() {
  local iso="$1"
  local dev="$2"
  local stable=''
  local answer=''

  stable="$(stable_device_path "$dev")"

  printf '\n'
  warn "About to destroy all data on: ${stable}"
  printf 'ISO   : %s\n' "$iso"
  printf 'Target: %s\n\n' "$stable"
  printf 'Type the exact device path to continue: '
  read -r answer

  [[ "$answer" == "$stable" || "$answer" == "$dev" ]] || \
    die 'Confirmation failed.'
}

function write_with_pv() {
  local iso="$1"
  local dev="$2"
  local size=''

  need_cmd pv
  size="$(stat -c '%s' "$iso")"

  log "Writing with pv to ${dev}"
  pv -pterab -s "$size" -Y "$iso" > "$dev"
  sync
  blockdev --flushbufs "$dev" 2>/dev/null || true
}

function write_with_ddrescue() {
  local iso="$1"
  local dev="$2"
  local mapfile=''

  need_cmd ddrescue
  mapfile="$(mktemp /tmp/archiso-ddrescue.XXXXXX.map)"

  log "Writing with ddrescue to ${dev}"
  ddrescue --force "$iso" "$dev" "$mapfile"
  sync
  blockdev --flushbufs "$dev" 2>/dev/null || true
  rm -f "$mapfile"
}

function maybe_eject() {
  local dev="$1"

  if has_cmd eject; then
    eject "$dev" || true
  else
    warn 'eject not found; skipping eject.'
  fi
}

function newest_iso_matching() {
  local out_dir="$1"
  local iso_name="$2"
  local result=''

  result="$({
    find "$out_dir" -maxdepth 1 -type f -name '*.iso' -printf '%T@\t%p\n' \
      2>/dev/null || true
  } | sort -r -n -k1,1 | awk -F '\t' -v stem="$iso_name" '
    index($2, "/" stem "-") || index($2, "/" stem ".") { print $2; exit }
  ')"

  [[ -n "$result" ]] || die "Could not find ISO matching stem: ${iso_name}"
  printf '%s\n' "$result"
}

function cmd_build() {
  local profile_name='heini'
  local iso_name=''
  local iso_label=''
  local iso_version=''
  local install_dir=''
  local state_root="$PWD/.archiso-state"
  local out_dir="$PWD/out"
  local overlay_dir=''
  local scripts_dir=''
  local packages_file=''
  local with_bios=0
  local hostname_name=''
  local locale_name=''
  local keymap_name=''
  local timezone_name=''
  local enable_sshd=0
  local root_auth_keys=''
  local prune_work=0
  local extra_packages=()
  local profile_src=''
  local work_dir=''
  local profiledef=''
  local packages_dst=''
  local airootfs=''
  local item=''
  local releng_dir='/usr/share/archiso/configs/releng'

  while (($# > 0)); do
    case "$1" in
      --profile-name)         profile_name="$2"; shift 2 ;;
      --iso-name)             iso_name="$2"; shift 2 ;;
      --iso-label)            iso_label="$2"; shift 2 ;;
      --iso-version)          iso_version="$2"; shift 2 ;;
      --install-dir)          install_dir="$2"; shift 2 ;;
      --state-root)           state_root="$2"; shift 2 ;;
      --outdir)               out_dir="$2"; shift 2 ;;
      --overlay)              overlay_dir="$2"; shift 2 ;;
      --scripts-dir)          scripts_dir="$2"; shift 2 ;;
      --packages-file)        packages_file="$2"; shift 2 ;;
      --pkg)                  extra_packages+=("$2"); shift 2 ;;
      --with-bios)            with_bios=1; shift ;;
      --hostname)             hostname_name="$2"; shift 2 ;;
      --locale)               locale_name="$2"; shift 2 ;;
      --keymap)               keymap_name="$2"; shift 2 ;;
      --timezone)             timezone_name="$2"; shift 2 ;;
      --enable-sshd)          enable_sshd=1; shift ;;
      --root-authorized-keys) root_auth_keys="$2"; shift 2 ;;
      --prune-work)           prune_work=1; shift ;;
      -h|--help)              show_help; exit 0 ;;
      *) die "Unknown build argument: $1" ;;
    esac
  done

  ensure_root
  need_cmd mkarchiso
  need_cmd rsync
  need_cmd sed
  need_cmd awk
  need_cmd install
  [[ -d "$releng_dir" ]] || die 'Install archiso first.'

  profile_name="$(sanitize_name "$profile_name")"
  iso_name="$(sanitize_name "${iso_name:-$profile_name}")"
  iso_label
