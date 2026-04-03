#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# install-alacritty-from-source.sh
#
# Build Alacritty from a local git checkout and install:
#   - binary into /usr/local/bin
#   - terminfo entry
#   - desktop file into /usr/local/share/applications
#   - icons into /usr/local/share/icons/hicolor/...
#   - man page into /usr/local/share/man/man1
#   - optional shell completions (bash/zsh/fish) if present in repo
#
# Usage:
#   ./install-alacritty-from-source.sh [OPTIONS] /path/to/alacritty/repo
#
# Options:
#   -j, --jobs N        Parallel build jobs (default: nproc)
#   --prefix PATH       Install prefix (default: /usr/local)
#   --features STR      Cargo features (default: all-features)
#   --no-terminfo       Skip terminfo install
#   --no-desktop        Skip desktop entry install
#   --no-icons          Skip icon install
#   --no-man            Skip man page install
#   --no-completions    Skip shell completions install
#   -h, --help          Show help
# -----------------------------------------------------------------------------

function die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

function show_help() {
  cat <<'EOF'
install-alacritty-from-source.sh

Build & install Alacritty from a local repository checkout.

Usage:
  ./install-alacritty-from-source.sh [OPTIONS] /path/to/alacritty/repo

Options:
  -j, --jobs N        Parallel build jobs (default: nproc)
  --prefix PATH       Install prefix (default: /usr/local)
  --features STR      Cargo features (default: all-features)
  --no-terminfo       Skip terminfo install
  --no-desktop        Skip desktop entry install
  --no-icons          Skip icon install
  --no-man            Skip man page install
  --no-completions    Skip shell completions install
  -h, --help          Show help

Notes:
- You will likely need system deps on Arch (examples):
    sudo pacman -S --needed base-devel rust cargo cmake pkgconf \
      freetype2 fontconfig libxcb libxkbcommon wayland wayland-protocols \
      python scdoc
- This script installs to /usr/local by default.
EOF
}

# ------------------------------ defaults --------------------------------------
jobs="$(nproc)"
prefix="/usr/local"
features="all-features"
do_terminfo=1
do_desktop=1
do_icons=1
do_man=1
do_completions=1

repo=""

# ------------------------------ parse args -----------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -j|--jobs)
      [[ $# -ge 2 ]] || die "Missing argument for $1"
      jobs="$2"
      shift 2
      ;;
    --prefix)
      [[ $# -ge 2 ]] || die "Missing argument for $1"
      prefix="$2"
      shift 2
      ;;
    --features)
      [[ $# -ge 2 ]] || die "Missing argument for $1"
      features="$2"
      shift 2
      ;;
    --no-terminfo)    do_terminfo=0; shift ;;
    --no-desktop)     do_desktop=0; shift ;;
    --no-icons)       do_icons=0; shift ;;
    --no-man)         do_man=0; shift ;;
    --no-completions) do_completions=0; shift ;;
    -h|--help)        show_help; exit 0 ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      if [[ -z "${repo}" ]]; then
        repo="$1"
      else
        die "Unexpected extra argument: $1"
      fi
      shift
      ;;
  esac
done

[[ -n "${repo}" ]] || { show_help; die "Missing /path/to/alacritty/repo"; }
[[ -d "${repo}" ]] || die "Repo path does not exist: ${repo}"

command -v cargo >/dev/null 2>&1 || die "cargo not found in PATH"
command -v install >/dev/null 2>&1 || die "install(1) not found in PATH"

# ------------------------------ build ----------------------------------------
cd "${repo}"

# Sanity: ensure this looks like an Alacritty repo (Cargo.toml present).
[[ -f Cargo.toml ]] || die "No Cargo.toml in repo root: ${repo}"

printf '==> Building Alacritty (release, %s, jobs=%s)\n' "${features}" "${jobs}"

if [[ "${features}" == "all-features" ]]; then
  cargo build --release --all-features -j "${jobs}"
else
  cargo build --release --features "${features}" -j "${jobs}"
fi

bin_path="target/release/alacritty"
[[ -x "${bin_path}" ]] || die "Build succeeded but binary missing: ${bin_path}"

# ------------------------------ install binary --------------------------------
printf '==> Installing binary to %s/bin\n' "${prefix}"
sudo install -Dm755 "${bin_path}" "${prefix}/bin/alacritty"

# ------------------------------ terminfo --------------------------------------
# Alacritty typically ships terminfo in extra/alacritty.info (path may vary).
if [[ "${do_terminfo}" -eq 1 ]]; then
  info_candidates=(
    "extra/alacritty.info"
    "extra/alacritty/alacritty.info"
    "extra/terminfo/alacritty.info"
  )
  info_file=""
  for f in "${info_candidates[@]}"; do
    if [[ -f "${f}" ]]; then info_file="${f}"; break; fi
  done

  if [[ -n "${info_file}" ]]; then
    command -v tic >/dev/null 2>&1 || die "tic(1) not found (ncurses). Install ncurses."
    printf '==> Installing terminfo from %s\n' "${info_file}"
    # Install both common entries if present in file.
    sudo tic -xe alacritty,alacritty-direct "${info_file}" || \
      sudo tic "${info_file}"
  else
    printf '==> terminfo: not found in repo (skipping)\n'
  fi
fi

# ------------------------------ desktop entry ---------------------------------
# Usually in extra/linux/Alacritty.desktop (name may differ).
if [[ "${do_desktop}" -eq 1 ]]; then
  desktop_candidates=(
    "extra/linux/Alacritty.desktop"
    "extra/linux/alacritty.desktop"
    "extra/Alacritty.desktop"
  )
  desktop_file=""
  for f in "${desktop_candidates[@]}"; do
    if [[ -f "${f}" ]]; then desktop_file="${f}"; break; fi
  done

  if [[ -n "${desktop_file}" ]]; then
    printf '==> Installing desktop file to %s/share/applications\n' "${prefix}"
    sudo install -Dm644 "${desktop_file}" \
      "${prefix}/share/applications/Alacritty.desktop"

    if command -v update-desktop-database >/dev/null 2>&1; then
      sudo update-desktop-database "${prefix}/share/applications" || true
    fi
  else
    printf '==> desktop file: not found in repo (skipping)\n'
  fi
fi

# ------------------------------ icons -----------------------------------------
# Alacritty typically ships SVG/PNG icons under extra/logo/.
if [[ "${do_icons}" -eq 1 ]]; then
  icon_dir="extra/logo"
  if [[ -d "${icon_dir}" ]]; then
    printf '==> Installing icons into hicolor theme under %s/share/icons\n' \
      "${prefix}"

    # Prefer PNGs if available; fall back to SVG where appropriate.
    # Common sizes: 16, 32, 64, 128, 256, 512.
    shopt -s nullglob
    for png in "${icon_dir}"/alacritty-term-*.png "${icon_dir}"/alacritty-*.png; do
      base="$(basename "${png}")"
      # Try to extract size digits from filename.
      if [[ "${base}" =~ ([0-9]{2,4}) ]]; then
        size="${BASH_REMATCH[1]}"
        sudo install -Dm644 "${png}" \
          "${prefix}/share/icons/hicolor/${size}x${size}/apps/Alacritty.png"
      fi
    done
    shopt -u nullglob

    # Install an SVG as scalable icon if present.
    if [[ -f "${icon_dir}/alacritty-term.svg" ]]; then
      sudo install -Dm644 "${icon_dir}/alacritty-term.svg" \
        "${prefix}/share/icons/hicolor/scalable/apps/Alacritty.svg"
    elif [[ -f "${icon_dir}/alacritty.svg" ]]; then
      sudo install -Dm644 "${icon_dir}/alacritty.svg" \
        "${prefix}/share/icons/hicolor/scalable/apps/Alacritty.svg"
    fi

    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
      # Update only the prefix hicolor cache if it exists.
      hicolor="${prefix}/share/icons/hicolor"
      if [[ -d "${hicolor}" ]]; then
        sudo gtk-update-icon-cache -q "${hicolor}" || true
      fi
    fi
  else
    printf '==> icons: %s not found (skipping)\n' "${icon_dir}"
  fi
fi

# ------------------------------ man page --------------------------------------
# Manpage often in extra/alacritty.man (scdoc source) or prebuilt.
if [[ "${do_man}" -eq 1 ]]; then
  man_candidates=(
    "extra/alacritty.man"
    "extra/man/alacritty.1"
    "docs/alacritty.1"
  )
  man_src=""
  for f in "${man_candidates[@]}"; do
    if [[ -f "${f}" ]]; then man_src="${f}"; break; fi
  done

  if [[ -n "${man_src}" ]]; then
    mkdir -p "target/man"
    if [[ "${man_src}" == *.man ]]; then
      command -v scdoc >/dev/null 2>&1 || \
        printf '==> scdoc not found; cannot build man from %s (skipping)\n' \
          "${man_src}"
      if command -v scdoc >/dev/null 2>&1; then
        scdoc < "${man_src}" > "target/man/alacritty.1"
        sudo install -Dm644 "target/man/alacritty.1" \
          "${prefix}/share/man/man1/alacritty.1"
      fi
    else
      sudo install -Dm644 "${man_src}" \
        "${prefix}/share/man/man1/alacritty.1"
    fi
  else
    printf '==> man page: not found in repo (skipping)\n'
  fi
fi

# ------------------------------ completions -----------------------------------
# Paths vary across versions; we search a few common locations.
if [[ "${do_completions}" -eq 1 ]]; then
  printf '==> Installing shell completions (if found)\n'

  # Candidates:
  # - extra/completions/alacritty.(bash|zsh|fish)
  # - extra/shell-completions/...
  # - target/release/build/... generated (hard to locate reliably)
  comp_base_candidates=(
    "extra/completions"
    "extra/shell-completions"
    "completions"
  )

  comp_dir=""
  for d in "${comp_base_candidates[@]}"; do
    if [[ -d "${d}" ]]; then comp_dir="${d}"; break; fi
  done

  if [[ -n "${comp_dir}" ]]; then
    # bash
    if [[ -f "${comp_dir}/alacritty.bash" ]]; then
      sudo install -Dm644 "${comp_dir}/alacritty.bash" \
        "${prefix}/share/bash-completion/completions/alacritty"
    fi
    # zsh
    if [[ -f "${comp_dir}/_alacritty" ]]; then
      sudo install -Dm644 "${comp_dir}/_alacritty" \
        "${prefix}/share/zsh/site-functions/_alacritty"
    elif [[ -f "${comp_dir}/alacritty.zsh" ]]; then
      sudo install -Dm644 "${comp_dir}/alacritty.zsh" \
        "${prefix}/share/zsh/site-functions/_alacritty"
    fi
    # fish
    if [[ -f "${comp_dir}/alacritty.fish" ]]; then
      sudo install -Dm644 "${comp_dir}/alacritty.fish" \
        "${prefix}/share/fish/vendor_completions.d/alacritty.fish"
    fi
  else
    printf '==> completions: not found in repo (skipping)\n'
  fi
fi

printf '==> Done.\n'
printf '    Binary: %s/bin/alacritty\n' "${prefix}"

