#!/usr/bin/env bash
#
# Apply or restore host-relative WSL 2 resource profiles from inside WSL.
#
# Managed files:
#   %USERPROFILE%/.wslconfig  Global WSL 2 VM resource limits.
#   /etc/wsl.conf            Per-distribution Linux-side settings.
#
# Presets:
#   low       25% RAM,  25% logical CPUs
#   balanced  40% RAM,  50% logical CPUs
#   medium    50% RAM,  75% logical CPUs
#   high      75% RAM, 100% logical CPUs
#   standard  Restore native/unmanaged configuration
#
# The script records the original state of each file before first modifying it.
# "standard" restores that original, or removes the managed file when none
# originally existed.

set -euo pipefail

readonly MANAGED_MARKER='# Managed by Set-WSLProfile'

preset='balanced'
no_distro_config=0
dry_run=0

function usage()
{
  cat <<'EOF_USAGE'
Usage:
  set-wsl-profile.sh [OPTIONS] [PRESET]

PRESET:
  low       25% host RAM,  25% logical CPUs
  balanced  40% host RAM,  50% logical CPUs  [default]
  medium    50% host RAM,  75% logical CPUs
  high      75% host RAM, 100% logical CPUs
  standard  Restore original files or native WSL defaults

OPTIONS:
  --no-distro-config  Do not modify /etc/wsl.conf.
  -n, --dry-run       Show calculated values and files; change nothing.
  -h, --help          Show this help.

The generated /etc/wsl.conf enables systemd and retains ordinary WSL automount
and Windows-interoperability behavior. RAM, CPU and swap limits are controlled
only by the Windows-side %USERPROFILE%/.wslconfig file.

Examples:
  set-wsl-profile.sh balanced
  set-wsl-profile.sh high
  set-wsl-profile.sh low --no-distro-config
  set-wsl-profile.sh standard
  set-wsl-profile.sh medium --dry-run

After applying a non-dry-run change, exit WSL and run this from Windows:

  wsl.exe --shutdown

Then start the distribution again.
EOF_USAGE
}

function die()
{
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

function find_powershell()
{
  local candidate=''

  if command -v powershell.exe >/dev/null 2>&1; then
    command -v powershell.exe
    return 0
  fi

  for candidate in \
    '/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe' \
    '/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
  do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

function get_host_info()
{
  local ps_exe="$1"
  local result=''

  result="$($ps_exe -NoLogo -NoProfile -NonInteractive -Command \
    '$c=Get-CimInstance Win32_ComputerSystem; '"\
"'[Console]::Write("{0}|{1}|{2}", '"\
"'[math]::Floor($c.TotalPhysicalMemory/1MB), '"\
"'$c.NumberOfLogicalProcessors, $env:USERPROFILE)' \
    2>/dev/null | tr -d '\r')"

  [[ "$result" == *'|'*'|'* ]] || \
    die 'Could not query RAM, CPU count and Windows profile path.'

  printf '%s\n' "$result"
}

function round_nearest_512()
{
  local value_mb="$1"
  printf '%d\n' $(( ((value_mb + 256) / 512) * 512 ))
}

function ceil_quarter_to_512()
{
  local memory_mb="$1"
  local quarter_mb=$(( (memory_mb + 3) / 4 ))
  printf '%d\n' $(( ((quarter_mb + 511) / 512) * 512 ))
}

function calculate_profile()
{
  local name="$1"
  local host_mb="$2"
  local host_cpu="$3"
  local mem_num=0
  local mem_den=100
  local cpu_num=0
  local cpu_den=100
  local raw_memory=0
  local memory_mb=0
  local processors=0
  local swap_mb=0

  case "$name" in
    low)
      mem_num=25
      cpu_num=25
      ;;
    balanced)
      mem_num=40
      cpu_num=50
      ;;
    medium)
      mem_num=50
      cpu_num=75
      ;;
    high)
      mem_num=75
      cpu_num=100
      ;;
    *)
      die "No resource calculation exists for preset '$name'."
      ;;
  esac

  raw_memory=$(( (host_mb * mem_num + mem_den / 2) / mem_den ))
  memory_mb="$(round_nearest_512 "$raw_memory")"

  if (( host_mb >= 4096 && memory_mb < 2048 )); then
    memory_mb=2048
  fi
  if (( memory_mb > host_mb )); then
    memory_mb="$host_mb"
  fi

  processors=$(( (host_cpu * cpu_num + cpu_den - 1) / cpu_den ))
  (( processors < 1 )) && processors=1
  (( processors > host_cpu )) && processors="$host_cpu"

  swap_mb="$(ceil_quarter_to_512 "$memory_mb")"
  (( swap_mb < 1024 )) && swap_mb=1024

  printf '%d|%d|%d\n' "$memory_mb" "$processors" "$swap_mb"
}

function global_config()
{
  local name="$1"
  local memory_mb="$2"
  local processors="$3"
  local swap_mb="$4"

  cat <<EOF_CONFIG
$MANAGED_MARKER
# Resource profile: $name
# Generated from the current Windows host resources.

[wsl2]
memory=${memory_mb}MB
processors=${processors}
swap=${swap_mb}MB
localhostForwarding=true
EOF_CONFIG
}

function distro_config()
{
  cat <<EOF_CONFIG
$MANAGED_MARKER
# Developer-friendly per-distribution WSL settings.
# Resource limits belong in %USERPROFILE%/.wslconfig, not this file.

[boot]
systemd=true

[automount]
enabled=true
mountFsTab=true

[interop]
enabled=true
appendWindowsPath=true
EOF_CONFIG
}

function save_original_state()
{
  local target="$1"
  local backup="${target}.wsl-profile.original"
  local missing="${target}.wsl-profile.no-original"

  if [[ -e "$backup" || -e "$missing" ]]; then
    return 0
  fi

  if [[ -e "$target" ]]; then
    cp -p -- "$target" "$backup"
  else
    : > "$missing"
  fi
}

function write_file()
{
  local target="$1"
  local content="$2"
  local mode="${3:-}"
  local tmp="${target}.wsl-profile.tmp.$$"

  if (( dry_run )); then
    printf 'Would write: %s\n%s\n' "$target" "$content"
    return 0
  fi

  save_original_state "$target"
  printf '%s\n' "$content" > "$tmp"

  if [[ -n "$mode" ]]; then
    chmod "$mode" "$tmp"
  fi

  mv -f -- "$tmp" "$target"
  printf 'Updated %s\n' "$target"
}

function restore_file()
{
  local target="$1"
  local backup="${target}.wsl-profile.original"
  local missing="${target}.wsl-profile.no-original"
  local first=''

  if (( dry_run )); then
    printf 'Would restore native/original state for: %s\n' "$target"
    return 0
  fi

  if [[ -e "$backup" ]]; then
    mv -f -- "$backup" "$target"
    rm -f -- "$missing"
    printf 'Restored original %s\n' "$target"
    return 0
  fi

  if [[ -e "$missing" ]]; then
    rm -f -- "$target" "$missing"
    printf 'Removed managed %s; WSL defaults restored\n' "$target"
    return 0
  fi

  if [[ -e "$target" ]]; then
    IFS= read -r first < "$target" || true
    if [[ "$first" == "$MANAGED_MARKER" ]]; then
      rm -f -- "$target"
      printf 'Removed managed %s; WSL defaults restored\n' "$target"
    else
      printf 'Left unmanaged %s unchanged\n' "$target"
    fi
  fi
}

function ensure_root_for_distro_file()
{
  if (( no_distro_config || dry_run )); then
    return 0
  fi

  if (( EUID != 0 )); then
    command -v sudo >/dev/null 2>&1 || \
      die 'sudo is required to manage /etc/wsl.conf.'
  fi
}

function write_distro_file()
{
  local content="$1"

  if (( no_distro_config )); then
    return 0
  fi

  if (( dry_run )); then
    printf 'Would write: /etc/wsl.conf\n%s\n' "$content"
  elif (( EUID == 0 )); then
    write_file '/etc/wsl.conf' "$content" '0644'
  else
    local encoded=''
    encoded="$(printf '%s' "$content" | base64 -w 0)"
    sudo sh -c "
      set -eu
      target=/etc/wsl.conf
      backup=\"\${target}.wsl-profile.original\"
      missing=\"\${target}.wsl-profile.no-original\"
      if [ ! -e \"\$backup\" ] && [ ! -e \"\$missing\" ]; then
        if [ -e \"\$target\" ]; then
          cp -p -- \"\$target\" \"\$backup\"
        else
          : > \"\$missing\"
        fi
      fi
      printf '%s' '$encoded' | base64 -d > \"\$target\"
      chmod 0644 \"\$target\"
    "
    printf 'Updated /etc/wsl.conf\n'
  fi
}

function restore_distro_file()
{
  if (( no_distro_config )); then
    return 0
  fi

  if (( dry_run )); then
    printf 'Would restore native/original state for: /etc/wsl.conf\n'
  elif (( EUID == 0 )); then
    restore_file '/etc/wsl.conf'
  else
    local marker_b64=''
    marker_b64="$(printf '%s' "$MANAGED_MARKER" | base64 -w 0)"
    sudo sh -c "
      set -eu
      target=/etc/wsl.conf
      backup=\"\${target}.wsl-profile.original\"
      missing=\"\${target}.wsl-profile.no-original\"
      marker=\$(printf '%s' '$marker_b64' | base64 -d)
      if [ -e \"\$backup\" ]; then
        mv -f -- \"\$backup\" \"\$target\"
        rm -f -- \"\$missing\"
      elif [ -e \"\$missing\" ]; then
        rm -f -- \"\$target\" \"\$missing\"
      elif [ -e \"\$target\" ]; then
        first=\$(sed -n '1p' \"\$target\")
        if [ \"\$first\" = \"\$marker\" ]; then
          rm -f -- \"\$target\"
        fi
      fi
    "
    printf 'Restored /etc/wsl.conf to its original/native state\n'
  fi
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

positional=()
while (( $# )); do
  case "$1" in
    --no-distro-config)
      no_distro_config=1
      shift
      ;;
    -n|--dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      positional+=("$@")
      break
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done

if (( ${#positional[@]} > 1 )); then
  die 'Specify at most one preset.'
fi
if (( ${#positional[@]} == 1 )); then
  preset="${positional[0]}"
fi

case "$preset" in
  low|balanced|medium|high|standard)
    ;;
  *)
    die "Invalid preset: $preset"
    ;;
esac

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

ps_exe="$(find_powershell)" || \
  die 'Could not locate Windows PowerShell from inside WSL.'

host_info="$(get_host_info "$ps_exe")"
IFS='|' read -r host_mb host_cpu win_profile <<< "$host_info"

[[ "$host_mb" =~ ^[0-9]+$ ]] || die 'Invalid host memory value.'
[[ "$host_cpu" =~ ^[0-9]+$ ]] || die 'Invalid host processor count.'
[[ -n "$win_profile" ]] || die 'Windows USERPROFILE was empty.'

command -v wslpath >/dev/null 2>&1 || die 'wslpath was not found.'
win_profile_wsl="$(wslpath -u "$win_profile")"
global_target="${win_profile_wsl}/.wslconfig"

ensure_root_for_distro_file

if [[ "$preset" == 'standard' ]]; then
  restore_file "$global_target"
  restore_distro_file
else
  values="$(calculate_profile "$preset" "$host_mb" "$host_cpu")"
  IFS='|' read -r memory_mb processors swap_mb <<< "$values"

  awk -v mb="$host_mb" -v cpu="$host_cpu" \
    'BEGIN { printf "Host: %.1f GiB RAM, %d logical CPUs\n", mb/1024, cpu }'
  awk -v name="$preset" -v mb="$memory_mb" -v cpu="$processors" \
    -v swap="$swap_mb" \
    'BEGIN { printf "Preset %s: %.1f GiB RAM, %d CPUs, %.1f GiB swap\n", '"\
"'name, mb/1024, cpu, swap/1024 }'

  content="$(global_config \
    "$preset" "$memory_mb" "$processors" "$swap_mb")"
  write_file "$global_target" "$content"

  content="$(distro_config)"
  write_distro_file "$content"
fi

if (( ! dry_run )); then
  printf '\nApply VM-level changes after leaving WSL with:\n'
  printf '  wsl.exe --shutdown\n'
fi

