#!/bin/bash
# Build OpenWhisper and package into .app bundle
set -e

cd "$(dirname "$0")"

echo "Building OpenWhisper..."
swift build -c debug 2>&1

APP_DIR="build/OpenWhisper.app/Contents"
EXEC_SRC=".build/debug/OpenWhisper"
BUNDLE_SRC=".build/debug/OpenWhisper_OpenWhisper.bundle"

# Copy executable
cp "$EXEC_SRC" "$APP_DIR/MacOS/OpenWhisper"

# Copy resource bundle if exists
if [ -d "$BUNDLE_SRC" ]; then
    cp -R "$BUNDLE_SRC" "$APP_DIR/Resources/"
fi

# Copy any framework dependencies
if [ -d ".build/debug/PackageFrameworks" ]; then
    mkdir -p "$APP_DIR/Frameworks"
    cp -R .build/debug/PackageFrameworks/* "$APP_DIR/Frameworks/" 2>/dev/null || true
fi

# Sign with persistent certificate (survives rebuilds — no need to re-grant Accessibility)
CERT_NAME="OpenWhisper Developer"
if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "Signing with '$CERT_NAME' certificate..."
    codesign --force --deep --sign "$CERT_NAME" "build/OpenWhisper.app"
    echo ""
    echo "Done! App bundle at: build/OpenWhisper.app"
    echo "  Signed with persistent certificate — Accessibility permission is preserved."
else
    echo "No persistent certificate found, falling back to ad-hoc signing..."
    codesign --force --deep --sign - "build/OpenWhisper.app"
    # Reset Accessibility TCC entry so the new binary gets a fresh grant
    echo "Resetting Accessibility permission (you'll need to re-grant it)..."
    tccutil reset Accessibility com.openwhisper.app 2>/dev/null || true
    echo ""
    echo "Done! App bundle at: build/OpenWhisper.app"
    echo ""
    echo "  IMPORTANT: After launching, grant Accessibility permission:"
    echo "  System Settings → Privacy & Security → Accessibility → Toggle ON OpenWhisper"
    echo "  Then restart the app."
fi
echo ""
