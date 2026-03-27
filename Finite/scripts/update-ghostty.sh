#!/usr/bin/env bash
set -euo pipefail

# Updates the local Ghostty checkout and rebuilds GhosttyKit if needed.
# Can be run manually or by the LaunchAgent.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GHOSTTY_DIR="${GHOSTTY_SOURCE_DIR:-$(cd "$PROJECT_DIR/.." && pwd)/ghostty}"
LOG_FILE="$HOME/.cache/finite/update.log"

mkdir -p "$(dirname "$LOG_FILE")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

if [ ! -d "$GHOSTTY_DIR/.git" ]; then
    log "Error: Ghostty source not found at $GHOSTTY_DIR"
    exit 1
fi

OLD_SHA="$(git -C "$GHOSTTY_DIR" rev-parse HEAD)"
log "==> Current Ghostty: $OLD_SHA"

log "==> Pulling latest Ghostty..."
git -C "$GHOSTTY_DIR" pull --ff-only 2>&1 | tee -a "$LOG_FILE" || {
    log "Warning: pull failed (dirty tree or diverged). Skipping."
    exit 0
}

NEW_SHA="$(git -C "$GHOSTTY_DIR" rev-parse HEAD)"

if [ "$OLD_SHA" = "$NEW_SHA" ]; then
    log "==> Already up to date."
    exit 0
fi

log "==> Ghostty updated: $OLD_SHA → $NEW_SHA"
log "==> Rebuilding GhosttyKit..."

# Run setup.sh which handles building, caching, and symlinking
"$SCRIPT_DIR/setup.sh" 2>&1 | tee -a "$LOG_FILE"

log "==> GhosttyKit updated to $NEW_SHA"

# Write marker so the running app knows an update is available
MARKER_FILE="$HOME/.cache/finite/update-available.json"
cat > "$MARKER_FILE" <<MARKER_EOF
{"sha":"$NEW_SHA","old_sha":"$OLD_SHA","date":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
MARKER_EOF
log "==> Wrote update marker to $MARKER_FILE"
