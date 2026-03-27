#!/usr/bin/env bash
set -euo pipefail

# Called by Finite.app to rebuild, reinstall, and relaunch itself.
# The app quits before calling this so we can replace the bundle.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="Finite.app"
INSTALL_DIR="/Applications"
MARKER_FILE="$HOME/.cache/finite/update-available.json"
LOG_FILE="$HOME/.cache/finite/update.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

cd "$PROJECT_DIR"

log "==> Building release..."
xcodebuild -project Finite.xcodeproj -scheme Finite -configuration Release build 2>&1 | tee -a "$LOG_FILE" | tail -5

APP=$(find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Finite-*/Build/Products/Release/$APP_NAME" -maxdepth 5 2>/dev/null | head -1)

if [ -z "$APP" ]; then
    log "Error: could not find built $APP_NAME"
    # Try to relaunch the old version
    open "$INSTALL_DIR/$APP_NAME"
    exit 1
fi

log "==> Installing to $INSTALL_DIR..."
rm -rf "$INSTALL_DIR/$APP_NAME"
cp -R "$APP" "$INSTALL_DIR/$APP_NAME"

# Clear the update marker
rm -f "$MARKER_FILE"

log "==> Relaunching..."
open "$INSTALL_DIR/$APP_NAME"

log "==> Update complete."
