#!/usr/bin/env bash
set -Eeuo pipefail

# rust-build-install — Build & install Rust binaries (and optional extras)
# - Autodetects project path if omitted (inside a Git repo with Cargo.toml)
# - Builds with configurable features/profile/jobs

# - Installs all produced binaries (from cargo JSON messages) to /usr/local/bin
# (or ~/.local/bin)
# - Optional: install .desktop, icon, terminfo, and manpages (scdoc or prebuilt)
#
# REQUIREMENTS:
#   - cargo, rustup

# - jq (preferred; used to parse cargo JSON output), fallback: scans
# target/<profile>
#   - desktop-file-install, update-desktop-database (if installing desktop file)
#   - scdoc + gzip (if installing .scd manpages)
#
# EXIT CODES:
#   0 success; non-zero on error

# --------------------------- Defaults & Globals --------------------------- #
SCRIPT_NAME="${0##*/}"
DEFAULT_JOBS="$(command -v nproc > /dev/null 2>&1 && nproc || printf '%s' 8)"
PROFILE="release" # or 'debug'
JOBS="$DEFAULT_JOBS"
BIN_DIR="/usr/local/bin" # use --local to switch to ~/.local/bin
PROJECT_DIR=""
USE_ALL_FEATURES=0
USE_NO_DEFAULT_FEATURES=0
FEATURES_LIST=""
BUILD_BINS_ONLY=0
MESSAGE_FORMAT_JSON=1

DESKTOP_FILE=""                   # path to .desktop
ICON_SPEC=""                      # SRC[:DEST_BASENAME.svg]
TIC_FILE=""                       
# path to terminfo source (.ti|.info). Use --tic-names to pass -e list
TIC_NAMES=""                      # comma-separated names for tic -e
declare -a MAN_SOURCES=()         # paths to .scd or .[1-9] or .[1-9].gz
MAN_PREFIX="/usr/local/share/man" # can be overridden with --man-prefix
DRYRUN=0

# bat fallback cat
BAT_OPTS=(--style="grid,header,snip" --italic-text="always" --theme="gruvbox-dark"
  --squeeze-blank --squeeze-limit="2" --force-colorization
  --terminal-width="auto" --tabs="2" --paging="never" --chop-long-lines)

bat_or_cat() {
  if command -v bat > /dev/null 2>&1; then bat "${BAT_OPTS[@]}"; else cat; fi
}

print_help() {
  cat << 'EOF' | bat_or_cat
# rust-build-install — Build & install Rust binaries (and optional extras)

**Usage**
  rust-build-install [OPTIONS] [--path <project_dir>]

**Behavior**
  - If --path is omitted, the script autodetects the project in the current directory
    by requiring: inside a Git work tree AND a Cargo.toml in that directory.
  - Builds with cargo and installs all produced binaries into the chosen bin dir.

**Options (Build)**
  -p, --path DIR                 Project directory (contains Cargo.toml). If omitted, autodetect in $PWD.
  -r, --release                  Use release profile (default).
  -d, --debug                    Use debug profile.
  -j, --jobs N                   Parallel jobs for cargo (default: CPU cores).
  -A, --all-features             Enable all features.
  -N, --no-default-features      Disable default features.
  -F, --features "a,b,c"         Comma-separated list of features (quoted).
  -B, --bins                     Build only binary targets (not libs/examples).
      --no-json                  Do not use cargo JSON messages (fallback file scan).

**Options (Install)**
  -L, --local                    Install to ~/.local/bin (creates it if needed).
      --bin-dir DIR             Install binaries to DIR (overrides --local).
      --man-prefix DIR          Install manual pages under DIR (default: /usr/local/share/man).

**Options (Extras; all optional)**
      --desktop FILE            Install .desktop via desktop-file-install and update database.
      --icon SRC[:NAME.svg]     Install icon to /usr/share/pixmaps/NAME.svg (NAME defaults to src basename).
      --tic FILE                Compile terminfo from FILE via 'tic -x' (use --tic-names for -e list).
      --tic-names LIST          Comma-separated names for 'tic -e LIST' (e.g., "alacritty,alacritty-direct").
      --man FILE                Add a man source (repeatable). Supports:
                                - .scd (scdoc), .1/.5/etc (prebuilt), or .1.gz/.5.gz
                                The section is derived from the extension.
      --dry-run                 Print actions without performing them.
  -h, --help                    Show this help and exit.

**Examples**
  # Inside a Git/Cargo project:
  rust-build-install -A -B -j8

  # Build and install with explicit path and desktop/icon:
  rust-build-install --path ~/repos/alacritty -A -B \
    --desktop ~/repos/alacritty/extra/linux/Alacritty.desktop \
    --icon ~/repos/alacritty/extra/logo/alacritty-term.svg:Alacritty.svg

  # Install manpages built from scdoc:
  rust-build-install --man extra/man/alacritty.1.scd --man extra/man/alacritty.5.scd

**Notes**
  - Binaries are installed with 'install -Dm755'.
  - Uses sudo automatically when writing to system paths you cannot write to.
  - Your ~/.config for the app is never touched.
EOF
}

# --------------------------- Utilities --------------------------- #
log() { printf '[%s] %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() {
  printf '[%s:ERROR] %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}
need() { command -v "$1" > /dev/null 2>&1 || die "Missing required command: $1";
  }

maybe_sudo() {
  local dst="$1"
  shift || true
  if [ -w "$(dirname "$dst")" ] && [ -e "$(dirname "$dst")" ] || [ -w "$dst" ];
    then
    "$@"
  else
    sudo "$@"
  fi
}

install_file() {
  # install_file <src> <dst> [mode]
  local src="$1"
  local dst="$2"
  local mode="${3:-755}"
  [ -f "$src" ] || die "Install source not found: $src"
  log "install -Dm$mode '$src' '$dst'"
  ((DRYRUN)) || maybe_sudo "$dst" install -Dm"$mode" "$src" "$dst"
}

install_desktop() {
  local desktop="$1"
  need desktop-file-install
  need update-desktop-database
  [ -f "$desktop" ] || die "Desktop file not found: $desktop"
  log "desktop-file-install '$desktop'"
  ((DRYRUN)) || sudo desktop-file-install "$desktop"
  log "update-desktop-database"
  ((DRYRUN)) || sudo update-desktop-database
}

install_icon() {
  local spec="$1"
  local src dest base
  src="${spec%%:*}"
  [ -f "$src" ] || die "Icon source not found: $src"
  if [[ "$spec" == *:* ]]; then
    dest="/usr/share/pixmaps/${spec#*:}"
  else
    base="$(basename "$src")"
    dest="/usr/share/pixmaps/$base"
  fi
  install_file "$src" "$dest" 644
}

compile_tic() {
  local file="$1"
  [ -f "$file" ] || die "Terminfo source not found: $file"
  local cmd=(tic -x)
  if [[ -n "$TIC_NAMES" ]]; then cmd=(tic -xe "$TIC_NAMES"); fi
  log "${cmd[*]} '$file'"
  ((DRYRUN)) || sudo "${cmd[@]}" "$file"
}

install_man_one() {
  local src="$1"
  local sec=""
  local dst=""
  if [[ "$src" == *.scd ]]; then
    need scdoc
    need gzip
    sec="$(basename "$src")"
    sec="${sec##*.}"
    sec="${sec%.*}" # alacritty.1.scd -> "1"
    [[ "$sec" =~ ^[0-9]+[a-zA-Z]*$ ]] ||
      die "Cannot derive man section from: $src"
    dst="$MAN_PREFIX/man$sec/$(basename "${src%.scd}").gz"
    log "scdoc < '$src' | gzip -c > '$dst'"
    ((DRYRUN)) || {
      mkdir -p "$(dirname "$dst")"
      scdoc < "$src" | gzip -c | maybe_sudo "$dst" tee "$dst" > /dev/null
    }
  elif [[ "$src" =~ \.[0-9a-zA-Z]+\.gz$ ]]; then
    sec="${src##*.}"
    sec="${sec%.*}" # .1.gz -> 1
    dst="$MAN_PREFIX/man$sec/$(basename "$src")"
    install_file "$src" "$dst" 644
  elif [[ "$src" =~ \.[0-9a-zA-Z]+$ ]]; then
    sec="${src##*.}"
    dst="$MAN_PREFIX/man$sec/$(basename "$src").gz"
    log "gzip -c '$src' > '$dst'"
    ((DRYRUN)) || {
      mkdir -p "$(dirname "$dst")"
      gzip -c "$src" | maybe_sudo "$dst" tee "$dst" > /dev/null
    }
  else
    die "Unknown man source format: $src"
  fi
}

# --------------------------- Arg Parsing --------------------------- #
ARGS=()
while (($#)); do
  case "$1" in
    -h | --help)
      print_help
      exit 0
      ;;
    -p | --path)
      PROJECT_DIR="$2"
      shift 2
      ;;
    -r | --release)
      PROFILE="release"
      shift
      ;;
    -d | --debug)
      PROFILE="debug"
      shift
      ;;
    -j | --jobs)
      JOBS="$2"
      shift 2
      ;;
    -A | --all-features)
      USE_ALL_FEATURES=1
      shift
      ;;
    -N | --no-default-features)
      USE_NO_DEFAULT_FEATURES=1
      shift
      ;;
    -F | --features)
      FEATURES_LIST="$2"
      shift 2
      ;;
    -B | --bins)
      BUILD_BINS_ONLY=1
      shift
      ;;
    --no-json)
      MESSAGE_FORMAT_JSON=0
      shift
      ;;
    -L | --local)
      BIN_DIR="${HOME}/.local/bin"
      shift
      ;;
    --bin-dir)
      BIN_DIR="$2"
      shift 2
      ;;
    --desktop)
      DESKTOP_FILE="$2"
      shift 2
      ;;
    --icon)
      ICON_SPEC="$2"
      shift 2
      ;;
    --tic)
      TIC_FILE="$2"
      shift 2
      ;;
    --tic-names)
      TIC_NAMES="$2"
      shift 2
      ;;
    --man)
      MAN_SOURCES+=("$2")
      shift 2
      ;;
    --man-prefix)
      MAN_PREFIX="$2"
      shift 2
      ;;
    --dry-run)
      DRYRUN=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*) die "Unknown option: $1" ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

# --------------------------- Project autodetect --------------------------- #
if [[ -z "$PROJECT_DIR" ]]; then
  if git rev-parse --is-inside-work-tree > /dev/null 2>&1 &&
    [[ -f "Cargo.toml" ]]; then
    PROJECT_DIR="$PWD"
  else
    die "No --path given and current directory is not a Rust project (need Git work tree + Cargo.toml)."
  fi
fi
[[ -f "$PROJECT_DIR/Cargo.toml" ]] || die "Cargo.toml not found in: $PROJECT_DIR"

# --------------------------- Tooling checks --------------------------- #
need cargo
need install
if ((MESSAGE_FORMAT_JSON)); then need jq || true; fi

# --------------------------- Build --------------------------- #
pushd "$PROJECT_DIR" > /dev/null

# Pin to stable toolchain inside the repo (non-destructive)
if command -v rustup > /dev/null 2>&1; then
  rustup override set stable > /dev/null 2>&1 || true
fi

build_args=(build)
[[ "$PROFILE" == "release" ]] && build_args+=(--release)
((BUILD_BINS_ONLY)) && build_args+=(--bins)
((USE_ALL_FEATURES)) && build_args+=(--all-features)
((USE_NO_DEFAULT_FEATURES)) && build_args+=(--no-default-features)
[[ -n "$FEATURES_LIST" ]] && build_args+=(--features "$FEATURES_LIST")
build_args+=(-j "$JOBS")

log "cargo ${build_args[*]}  # in $PROJECT_DIR"
if ((MESSAGE_FORMAT_JSON)) && command -v jq > /dev/null 2>&1; then
  # Parse executables from cargo JSON output
  TMP_JSON="$(mktemp)"
  ((DRYRUN)) || cargo "${build_args[@]}" --message-format=json |
    tee "$TMP_JSON" > /dev/null
  mapfile -t EXECUTABLES < <(((DRYRUN)) && printf '' ||
    jq -r 'select(.executable!=null) | .executable' "$TMP_JSON" | sort -u)
  rm -f "${TMP_JSON:?}"
else
  # Fallback: scan target/<profile> for executable files
  target_dir="$(cargo metadata --no-deps -q | jq -r '.target_directory' 2> /dev/null || printf '%s' 'target')"
  prof_dir="$target_dir/$PROFILE"
  ((DRYRUN)) || cargo "${build_args[@]}"
  mapfile -t EXECUTABLES < <(find "$prof_dir" -maxdepth 1 -type f -perm -111 ! -name '*.so' ! -name '*.dylib' ! -name '*.rlib' -printf '%p\n' 2> /dev/null | sort -u)
fi

((${
# EXECUTABLES[@]})) || die "No executables produced. Consider adding --bins or
# check build output."

# --------------------------- Install binaries --------------------------- #
# Ensure BIN_DIR exists
if ((!DRYRUN)); then
  if [[ "$BIN_DIR" == "$HOME"* ]]; then
    mkdir -p "$BIN_DIR"
  else
    maybe_sudo "$BIN_DIR/." install -d "$BIN_DIR"
  fi
fi

for exe in "${EXECUTABLES[@]}"; do
  base="$(basename "$exe")"
  dst="$BIN_DIR/$base"
  install_file "$exe" "$dst" 755
done

# --------------------------- Extras --------------------------- #
if [[ -n "$DESKTOP_FILE" ]]; then install_desktop "$DESKTOP_FILE"; fi
if [[ -n "$ICON_SPEC" ]]; then install_icon "$ICON_SPEC"; fi
if [[ -n "$TIC_FILE" ]]; then compile_tic "$TIC_FILE"; fi

if ((${#MAN_SOURCES[@]})); then
  for m in "${MAN_SOURCES[@]}"; do
    install_man_one "$m"
  done
  # Optional man DB refresh (harmless if absent)
  if command -v mandb > /dev/null 2>&1; then
    log "mandb -q (refresh)"
    ((DRYRUN)) || sudo mandb -q || true
  fi
fi

popd > /dev/null

# --------------------------- Summary --------------------------- #
printf '\nInstall summary:\n' | bat_or_cat
{
  printf '  Project: %s\n' "$PROJECT_DIR"
  printf '  Profile: %s (jobs=%s)\n' "$PROFILE" "$JOBS"
  printf '  Bin dir: %s\n' "$BIN_DIR"
  printf '  Binaries installed:\n'
  for exe in "${EXECUTABLES[@]}"; do
    printf '    - %s -> %s/%s\n' "$exe" "$BIN_DIR" "$(basename "$exe")"
  done
  [[ -n "$DESKTOP_FILE" ]] &&
    printf '  Desktop: installed (%s)\n' "$DESKTOP_FILE"
  [[ -n "$ICON_SPEC" ]] && printf '  Icon:    installed (%s)\n' "$ICON_SPEC"
  [[ -n "$TIC_FILE" ]] &&
    printf '  Terminfo: compiled (%s) %s\n' "$TIC_FILE" "${TIC_NAMES:+[-e $TIC_NAMES]}"
  ((${
  # MAN_SOURCES[@]})) && printf '  Manpages: %d source(s)\n' "${#MAN_SOURCES[@]}"
} | bat_or_cat

exit 0
