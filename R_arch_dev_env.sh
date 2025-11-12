#!/usr/bin/env bash
# =============================================================================
# r_arch_dev_setup.sh — Bootstrap an Arch Linux R development environment
#
# This script requires sudo privileges for system-wide operations:
#   • Installing packages (R, RStudio, debtap, pacman-contrib, AUR helper)
#   • Creating/updating the local pacman repository (/var/cache/rbinpkg)
# User-specific files (~/.Renviron, ~/.Rprofile) will be placed in the original
# user's home (via SUDO_USER) and ownership corrected accordingly.
#
# This script will:
#   1. Check for and install required system dependencies
#   2. Download precompiled CRAN Debian binaries and convert to Arch packages
#   3. Create or update a local pacman repository for r-cran packages
#   4. Initialize a basic R development environment for the invoking user:
#        • Populate ~/.Renviron with custom library paths and CRAN mirror
#        • Create ~/.Rprofile to load useful defaults and bspm support
#   5. Optionally output verbose logs with file listings, real paths, and content
#   6. Provide a summary of all created files and how to inspect them
#
# Usage:
#   sudo ./r_arch_dev_setup.sh [options] pkg1 pkg2 ...
#
# Options:
#   -h | --help      Show this help message and exit
#   -v | --verbose   Enable verbose output (list files created, realpath, contents)
#
# Examples:
#   # Basic install of dplyr and ggplot2
#   sudo ./r_arch_dev_setup.sh dplyr ggplot2
#
#   # Verbose mode to see detailed file creation and contents
#   sudo ./r_arch_dev_setup.sh --verbose tidyr stringr
#
# After successful execution:
#   • Packages available via pacman: pacman -Sy; pacman -S r-cran-<pkg>
#   • List repository files:
#       find /var/cache/rbinpkg -maxdepth 1 -type f
#   • Inspect environment files for user "$SUDO_USER":
#       find ~${SUDO_USER} -maxdepth 1 -type f -name ".Renviron" -o -name ".Rprofile"
#       realpath ~${SUDO_USER}/.Renviron ~${SUDO_USER}/.Rprofile
#       cat ~${SUDO_USER}/.Renviron ~${SUDO_USER}/.Rprofile
#
# Requirements:
#   • Arch Linux (tested June 2025)
#   • Internet access to CRAN Debian binary repo
#   • An AUR helper (yay or paru) in PATH
#
# Notes:
#   • You must run this script with sudo; it will exit otherwise.
#   • User config files are written to the invoking user's home.
#   • To review all files created, use:
#       find /var/cache/rbinpkg ~${SUDO_USER}/.Renviron ~${SUDO_USER}/.Rprofile -type f -exec realpath {} \\
#         \; -exec ${VIEWER:-cat} {} \;
# =============================================================================

# Exit if not run as root
if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] This script must be run with sudo."
  echo "Please rerun as: sudo $0 [options] pkg1 pkg2 ..."
  exit 1
fi

set -euo pipefail

# ────────────────────────────────────────────────────────────────────────────────
# Configuration
# ────────────────────────────────────────────────────────────────────────────────
REPO_DIR="/var/cache/rbinpkg"
CRAN_DEB_URL="https://cran.r-project.org/bin/linux/debian"
CRAN_DEB_DISTRO="bookworm-cran40"
CRAN_DEB_ARCH="amd64"
AUR_HELPER="yay"
VERBOSE=0
# Original user invoking via sudo
INV_USER="${SUDO_USER:-root}"
INV_HOME="$(eval echo ~${INV_USER})"

# ────────────────────────────────────────────────────────────────────────────────
# Logging helpers
# ────────────────────────────────────────────────────────────────────────────────
log()    { echo -e "[INFO]  $*"; }
verbose(){ (( VERBOSE )) && echo -e "[VERB]  $*"; }
# Choose content viewer: ccat if available, else cat
VIEWER="$( command -v ccat &>/dev/null && echo ccat || echo cat )"

# ────────────────────────────────────────────────────────────────────────────────
# Help function
# ────────────────────────────────────────────────────────────────────────────────
show_help(){ grep '^#' "$0" | sed -e 's/^#//' ; exit 0; }

# ────────────────────────────────────────────────────────────────────────────────
# Ensure command exists or install
# ────────────────────────────────────────────────────────────────────────────────
ensure_cmd(){ local cmd="$1" pkg="$2" via="$3"; 
  if ! command -v "$cmd" &>/dev/null; then
    log "'$cmd' not found. Installing $pkg..."
    case "$via" in
      pacman) pacman -Syu --needed --noconfirm "$pkg" ;; 
      aur)     "$AUR_HELPER" -S --noconfirm "$pkg" ;; 
      *) log "Unknown installer: $via"; exit 1;;
    esac
  fi
}

# ────────────────────────────────────────────────────────────────────────────────
# Query CRAN for latest version
# ────────────────────────────────────────────────────────────────────────────────
get_version(){ local pkg="$1";
  Rscript --quiet -e "cat(available.packages()[,'Version'][['$pkg']])";
}

# ────────────────────────────────────────────────────────────────────────────────
# Download and convert .deb to .pkg.tar.zst
# ────────────────────────────────────────────────────────────────────────────────
download_deb(){ local pkg="$1" ver="$2";
  local deb="r-cran-${pkg}_${ver}-${CRAN_DEB_DISTRO}_${CRAN_DEB_ARCH}.deb";
  local url="${CRAN_DEB_URL}/${CRAN_DEB_DISTRO}/${CRAN_DEB_ARCH}/${deb}";
  [[ -f "$deb" ]] || { log "Downloading $deb..."; wget -q "$url" -O "$deb"; }
  verbose "Downloaded: $(realpath "$deb")"; echo "$deb";
}
convert_deb(){ local debfile="$1";
  log "Converting $debfile to Arch package...";
  debtap "$debfile";
  local pkgzst=$(ls *.pkg.tar.zst | tail -n1);
  verbose "Converted: $(realpath "$pkgzst")";
}

# ────────────────────────────────────────────────────────────────────────────────
# Main script
# ────────────────────────────────────────────────────────────────────────────────

# Parse arguments
tmp_args=(); for arg; do
  case "$arg" in
    -h|--help) show_help ;;
    -v|--verbose) VERBOSE=1 ;;
    --) shift; break ;;
    -*) log "Unknown option: $arg"; exit 1;;
    *) tmp_args+=("$arg");;
  esac
done; set -- "${tmp_args[@]}"

# Ensure system dependencies
ensure_cmd uname coreutils pacman
ensure_cmd R r pacman
ensure_cmd repo-add pacman-contrib pacman
ensure_cmd "$AUR_HELPER" "$AUR_HELPER" pacman
ensure_cmd debtap debtap aur

# Install RStudio if missing
if ! command -v rstudio &>/dev/null; then
  log "rstudio not found. Installing rstudio-bin from AUR..."
  "$AUR_HELPER" -S --noconfirm rstudio-bin
fi

# Prepare local repo
action="Preparing local repo"
log "$action at $REPO_DIR"
mkdir -p "$REPO_DIR"
chown "$INV_USER:$INV_USER" "$REPO_DIR"
cd "$REPO_DIR"

# Process each R package
[[ $# -ge 1 ]] || { log "Usage: sudo $0 [options] pkg1 pkg2 ..."; exit 1; }
for pkg in "$@"; do
  log "=== Processing: $pkg ==="
  ver=$(get_version "$pkg")
  log "Version: $ver"
  deb=$(download_deb "$pkg" "$ver")
  convert_deb "$deb"
done

# Update pacman database
log "Updating pacman database..."
repo-add "${REPO_DIR}/r-cran.db.tar.gz" *.pkg.tar.zst
verbose "Repo DB: $(realpath ${REPO_DIR}/r-cran.db.tar.gz)"

# Scaffold user .Renviron and .Rprofile
log "Scaffolding R environment for $INV_USER"
RENFILE="$INV_HOME/.Renviron"
RPFFILE="$INV_HOME/.Rprofile"

# Write .Renviron
cat > "$RENFILE" << EOF
# Custom R environment
R_LIBS_USER="${INV_HOME}/R/x86_64-pc-linux-gnu-library/4.3"
CRAN="https://cloud.r-project.org"
EOF
chown "$INV_USER:$INV_USER" "$RENFILE"

# Write .Rprofile
cat > "$RPFFILE" << EOF
# Rprofile defaults
if (requireNamespace("bspm", quietly=TRUE)) bspm::use_extsoft()
options(stringsAsFactors = FALSE)
EOF
chown "$INV_USER:$INV_USER" "$RPFFILE"

# Verbose output of files\if (( VERBOSE )); then
  for file in "$RENFILE" "$RPFFILE"; do
    verbose "Created: $(realpath "$file")"
    verbose "Contents:" && su - "$INV_USER" -c "$VIEWER '$file'"
  done
fi

# Install/configure bspm in user R session
log "Configuring bspm for $INV_USER"
su - "$INV_USER" -c "Rscript --quiet -e 'if (!requireNamespace(\"bspm\", quietly=TRUE)) install.packages(\"bspm\"); bspm::enable()'"

# Final summary of created files
log "FINAL SUMMARY — Created files:"
find "$REPO_DIR" -maxdepth 1 -type f -exec realpath {} \;
realpath "$RENFILE" "$RPFFILE"

log "Setup complete: Arch R development environment ready for $INV_USER"
