#!/bin/bash
# OpenWhisper — one-line install & update script
# Usage: curl -fsSL https://raw.githubusercontent.com/Rajvardhman05/openwhisper-app/main/install.sh | bash
set -e

REPO="https://github.com/Rajvardhman05/openwhisper-app.git"
INSTALL_DIR="$HOME/.openwhisper"

echo "==> OpenWhisper installer"

# Check requirements
if [[ "$(uname -m)" != "arm64" ]]; then
    echo "Error: OpenWhisper requires Apple Silicon (M1/M2/M3/M4)."
    exit 1
fi

if ! xcode-select -p &>/dev/null; then
    echo "Error: Xcode Command Line Tools required. Run: xcode-select --install"
    exit 1
fi

# Quit running instance
pkill -x OpenWhisper 2>/dev/null && echo "==> Quit running OpenWhisper" || true

# Clone or update
if [ -d "$INSTALL_DIR/.git" ]; then
    echo "==> Updating existing install..."
    cd "$INSTALL_DIR"
    git pull --ff-only
else
    echo "==> Cloning OpenWhisper..."
    rm -rf "$INSTALL_DIR"
    git clone "$REPO" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

# Build and install
echo "==> Building..."
bash build.sh

# Launch
echo "==> Launching OpenWhisper..."
open /Applications/OpenWhisper.app 2>/dev/null || open build/OpenWhisper.app

echo ""
echo "  OpenWhisper is ready! Look for the microphone icon in your menu bar."
echo "  Hold Right Option key, speak, release to transcribe."
echo ""
echo "  To update later, run this same command again."
