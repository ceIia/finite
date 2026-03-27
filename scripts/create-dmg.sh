#!/usr/bin/env bash
set -euo pipefail

# Creates a styled DMG for Finite distribution.
# Usage: ./create-dmg.sh /path/to/Finite.app /output/dir

APP_PATH="${1:?Usage: create-dmg.sh <app-path> <output-dir>}"
OUTPUT_DIR="${2:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BG_IMAGE="$SCRIPT_DIR/../Finite/Resources/dmg-background.png"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
DMG_NAME="Finite-${VERSION}.dmg"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"
RW_DMG="$(mktemp -t finite-rw).dmg"

echo "==> Creating DMG for Finite $VERSION..."

# Create writable DMG
hdiutil create -volname "Finite" -srcfolder "$APP_PATH" -ov -format UDRW -fs HFS+ "$RW_DMG"
hdiutil attach "$RW_DMG" -mountpoint /Volumes/Finite

# Add Applications symlink and background
ln -s /Applications /Volumes/Finite/Applications
mkdir -p /Volumes/Finite/.background
cp "$BG_IMAGE" /Volumes/Finite/.background/bg.png

# Style the Finder window
osascript <<'APPLESCRIPT'
tell application "Finder"
    tell disk "Finite"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 1200, 748}
        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 100
        set label position of theViewOptions to bottom
        set background picture of theViewOptions to file ".background:bg.png"
        set position of item "Finite.app" of container window to {296, 310}
        set position of item "Applications" of container window to {729, 310}
        set extension hidden of item "Finite.app" to true
        close
        open
        update without registering applications
    end tell
end tell
APPLESCRIPT

sleep 2

# Convert to compressed read-only DMG
hdiutil detach /Volumes/Finite
rm -f "$DMG_PATH"
hdiutil convert "$RW_DMG" -format UDZO -o "$DMG_PATH"
rm "$RW_DMG"

echo "==> DMG created at $DMG_PATH"
