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

# Copy app icon and set in Info.plist
cp "OpenWhisper/Resources/AppIcon.icns" "$APP_DIR/Resources/AppIcon.icns" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$APP_DIR/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP_DIR/Info.plist"

# Copy any framework dependencies
if [ -d ".build/debug/PackageFrameworks" ]; then
    mkdir -p "$APP_DIR/Frameworks"
    cp -R .build/debug/PackageFrameworks/* "$APP_DIR/Frameworks/" 2>/dev/null || true
fi

install_app() {
    if [ "${SKIP_INSTALL:-}" != "1" ]; then
        echo "Installing to /Applications..."
        rm -rf /Applications/OpenWhisper.app
        cp -R build/OpenWhisper.app /Applications/
        echo "  Installed at /Applications/OpenWhisper.app"
        echo "  You can enable 'Launch at Login' in the app settings."
    fi
}

# Sign with persistent certificate (survives rebuilds — no need to re-grant Accessibility)
CERT_NAME="OpenWhisper Developer"
if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "Signing with '$CERT_NAME' certificate..."
    codesign --force --deep --sign "$CERT_NAME" "build/OpenWhisper.app"
    echo ""
    echo "Done! App bundle at: build/OpenWhisper.app"
    echo "  Signed with persistent certificate — Accessibility permission is preserved."
    install_app
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
    install_app
fi
echo ""
