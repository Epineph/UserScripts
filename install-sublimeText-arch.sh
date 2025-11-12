#!/usr/bin/env bash
#
# install-sublime-arch.sh — Install Sublime Text 4 + popular plugins on Arch Linux
#
# Usage:
#   ./install-sublime-arch.sh [-h]
#
# Options:
#   -h    Show this help message and exit
#
# What it does:
#   1. Ensures base-devel and git are installed
#   2. Installs 'yay' AUR helper if missing
#   3. Installs 'sublime-text-4' from the AUR
#   4. Creates Package Control user settings to auto-install a curated plugin set
#   5. Prints next steps to complete setup
#

set -euo pipefail

print_help() {
  sed -n '2,9p' "$0"
}

if [[ "${1:-}" == "-h" ]]; then
  print_help
  exit 0
fi

# 1. Ensure we can build AUR packages
echo "==> Installing base-devel, git, curl..."
sudo pacman -Syu --needed --noconfirm base-devel git curl

# 2. Install yay (if not already present)
if ! command -v yay &>/dev/null; then
  echo "==> Cloning and building yay (AUR helper)..."
  tmpdir=$(mktemp -d)
  git clone https://aur.archlinux.org/yay.git "$tmpdir/yay"
  pushd "$tmpdir/yay" >/dev/null
    makepkg -si --noconfirm
  popd >/dev/null
  rm -rf "$tmpdir"
else
  echo "==> yay already installed."
fi

# 3. Install Sublime Text 4
echo "==> Installing Sublime Text 4 from AUR..."
yay -S --noconfirm sublime-text-4

# 4. Bootstrap Package Control + plugin list
USER_CFG="$HOME/.config/sublime-text/Packages/User"
mkdir -p "$USER_CFG"

echo "==> Writing Package Control settings..."
cat > "$USER_CFG/Package Control.sublime-settings" <<'EOF'
{
  // On startup, Package Control will ensure these are installed:
  "installed_packages":
  [
    "Package Control",
    "Rainbow Brackets",
    "LSP",
    "LSP-pyright",
    "ShellCheck",
    "MarkdownEditing",
    "Emmet"
  ]
}
EOF

# 5. Remind user of next steps
cat <<EOF

✅ Installation complete!

Next steps:
  1. Launch Sublime Text:
       $ subl

  2. Wait a minute — Package Control will auto-install your plugins.

  3. (Optional) Tweak LSP settings via:
       Preferences → Package Settings → LSP → Settings

  4. Install any additional plugins by opening the Command Palette (Ctrl+Shift+P)
     and typing “Package Control: Install Package”.

Happy coding!
EOF

