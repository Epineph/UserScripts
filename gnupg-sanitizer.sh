#!/usr/bin/env bash
###############################################################################
# gpg-sanitise.sh                                                             #
#                                                                             #
# Audit and repair ownership and permissions of a GnuPG home directory,       #
# including detection and removal of pubring lock files.                      #
#                                                                             #
# USAGE                                                                       #
#   gpg-sanitise.sh [-d <dir>] [-n] [-h]                                       #
#                                                                             #
# OPTIONS                                                                     #
#   -d <path>   Target GnuPG directory (default: "$HOME/.gnupg").             #
#   -n          Dry-run mode: show actions without applying changes.           #
#   -h          Display this help message and exit.                           #
#                                                                             #
# EXIT CODES                                                                  #
#   0  Success (or dry-run completed).                                         #
#   1  Fatal error (e.g., directory inaccessible).                             #
###############################################################################

set -euo pipefail
IFS=$'\n\t'

### Default settings
DRY_RUN=false
GNUPG_DIR="$HOME/.gnupg"

### Print help/usage from header
print_help() {
  sed -n '1,60p' "$0" | sed 's/^#\s*//'
}

### Logging helpers
log_info()  { printf "[INFO]  %s\n" "$*"; }
log_warn()  { printf "[WARN]  %s\n" "$*"; }
log_error(){ printf "[ERROR] %s\n" "$*" >&2; }

### Execute or echo commands based on dry-run flag
run_cmd() {
  if [[ "$DRY_RUN" == true ]]; then
    printf "[DRY] %s\n" "$*"
  else
    eval "$*"
  fi
}

### Fix permissions for files or directories
# Args: <type: f|d> <mode> <base_path>
fix_permissions() {
  local type="$1" mode="$2" base="$3"
  find "$base" -type "$type" ! -perm "$mode" -print0 | \
    while IFS= read -r -d '' item; do
      run_cmd "sudo chmod $mode '$item'"
    done
}

### Remove stale lock files (older than given days)
remove_stale_locks() {
  local base="$1" days="$2"
  log_info "Removing lock files older than $days day(s)..."
  local locks
  locks=$(find "$base" -type f -name '*.lock' -mtime +"$days")
  if [[ -n "$locks" ]]; then
    printf "%s\n" "$locks" | while IFS= read -r lf; do
      run_cmd "rm -f '$lf'"
    done
  else
    log_info "No stale lock files found."
  fi
}

### Remove any pubring lock files (regardless of age)
remove_pubring_locks() {
  local base="$1"
  log_info "Checking for pubring lock files..."
  local locks
  locks=$(find "$base" -type f -name 'pubring*.lock')
  if [[ -n "$locks" ]]; then
    printf "%s\n" "$locks" | while IFS= read -r lf; do
      log_warn "Removing pubring lock: $lf"
      run_cmd "rm -f '$lf'"
    done
  else
    log_info "No pubring lock files detected."
  fi
}

### Parse command-line options
while getopts ":d:nh" opt; do
  case "$opt" in
    d) GNUPG_DIR="$OPTARG" ;;     # Specify GnuPG directory
    n) DRY_RUN=true ;;             # Enable dry-run mode
    h) print_help; exit 0 ;;        # Show help
    :) log_error "Option -$OPTARG requires an argument."; print_help; exit 1 ;;  
    \?) log_error "Unknown option: -$OPTARG"; print_help; exit 1 ;;        
  esac
done
shift $((OPTIND - 1))

### Preconditions
if [[ ! -d "$GNUPG_DIR" ]]; then
  log_error "Directory '$GNUPG_DIR' not found or inaccessible."
  exit 1
fi

### Determine user and group IDs
USER_ID=$(id -u)
GROUP_ID=$(id -g)

### Start sanitisation process
log_info "Sanitising GnuPG directory: $GNUPG_DIR"

# 1) Correct ownership
log_info "Setting ownership to $(id -un):$(id -gn)..."
run_cmd "sudo chown -R $USER_ID:$GROUP_ID '$GNUPG_DIR'"

# 2) Secure directories (700)
log_info "Applying directory permissions 700..."
fix_permissions d 700 "$GNUPG_DIR"

# 3) Secure files
## a) Private material → 600
log_info "Restricting private files to 600..."
find "$GNUPG_DIR" -type f \( \
    -path '*/private-keys-v1.d/*' -o \
    -name '*.gpg'            -o \
    -name 'trustdb.gpg'      \
\) -print0 | \
while IFS= read -r -d '' file; do
  run_cmd "chmod 600 '$file'"
done

## b) Public keyrings → 644 (includes .kbx and .db)
log_info "Setting public keyrings to 644..."
find "$GNUPG_DIR" -type f \( \
    -name 'pubring*.kbx' -o \
    -name 'pubring*.db'    \
\) -print0 | \
while IFS= read -r -d '' file; do
  run_cmd "chmod 644 '$file'"
done

## c) Other regular files → 600 (exclude above)
log_info "Restricting remaining files to 600..."
find "$GNUPG_DIR" -type f \
  ! -path '*/private-keys-v1.d/*' \
  ! -name '*.gpg'             \
  ! -name 'trustdb.gpg'       \
  ! -name 'pubring*.kbx'      \
  ! -name 'pubring*.db'       \
  -print0 | \
while IFS= read -r -d '' file; do
  run_cmd "chmod 600 '$file'"
done

# 4) Detect and remove any pubring lock files
remove_pubring_locks "$GNUPG_DIR"

# 5) Cleanup stale lock files older than 1 day
remove_stale_locks "$GNUPG_DIR" 1

# 6) Completion message
log_info "GnuPG directory sanitisation complete."

exit 0

