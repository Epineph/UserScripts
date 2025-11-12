#!/usr/bin/env bash
#
# setup-java-vscode.sh — Install and configure Java (OpenJDK) for VS Code# on Arch Linux
#
# Usage:
#   ./setup-java-vscode.sh
#
# Description:
#   - Installs OpenJDK (Temurin-compatible)
#   - Configures JAVA_HOME
#   - Updates VS Code settings.json with correct paths
#
# Requirements:
#   - jq
#   - code (Visual Studio Code CLI)
#
# Author: OpenAI ChatGPT — May 2025
# License: MIT
# -----------------------------------------------------------------------

set -euo pipefail

# -----------------------------------------------------------------------
# Environment and paths
# -----------------------------------------------------------------------
JAVA_PKG="jdk-openjdk"
JAVA_PATH="/usr/lib/jvm/java-21-openjdk"
: "${XDG_CONFIG_HOME:=$HOME/.config}"
VSCODE_USER_DIR="$XDG_CONFIG_HOME/Code/User"
SETTINGS_JSON="$VSCODE_USER_DIR/settings.json"

# -----------------------------------------------------------------------
# Install OpenJDK if not present
# -----------------------------------------------------------------------
if ! pacman -Qq "$JAVA_PKG" &>/dev/null; then
  echo "📦 Installing $JAVA_PKG..."
  sudo pacman -S --needed "$JAVA_PKG"
else
  echo "✔ $JAVA_PKG already installed."
fi

# -----------------------------------------------------------------------
# Ensure JAVA_HOME is available
# -----------------------------------------------------------------------
if [[ ! -d "$JAVA_PATH" ]]; then
  echo "❌ JAVA_PATH not found at $JAVA_PATH"
  exit 1
fi

export JAVA_HOME="$JAVA_PATH"
echo "✔ JAVA_HOME set to $JAVA_HOME"

# -----------------------------------------------------------------------
# Ensure VS Code settings.json exists
# -----------------------------------------------------------------------
mkdir -p "$VSCODE_USER_DIR"
touch "$SETTINGS_JSON"

# -----------------------------------------------------------------------
# Update VS Code settings.json with Java configuration
# -----------------------------------------------------------------------
tmp="$(mktemp)"
jq --arg path "$JAVA_PATH" '
  . + {
    "java.home": $path,
    "java.jdt.ls.java.home": $path,
    "java.import.gradle.java.home": $path,
    "java.import.maven.java.home": $path,
    "java.configuration.runtimes": [
      {
        "name": "JavaSE-21",
        "path": $path,
        "default": true
      }
    ]
  }
' "$SETTINGS_JSON" > "$tmp" && mv "$tmp" "$SETTINGS_JSON"

echo "✅ VS Code configured for Java at: $JAVA_PATH"

