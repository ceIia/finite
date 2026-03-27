#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GHOSTTY_DIR="${GHOSTTY_SOURCE_DIR:-$(cd "$PROJECT_DIR/.." && pwd)/ghostty}"

cd "$PROJECT_DIR"

echo "==> Checking for zig..."
if ! command -v zig &> /dev/null; then
    echo "Error: zig is not installed."
    echo "Install via: brew install zig"
    exit 1
fi

if [ ! -d "$GHOSTTY_DIR" ]; then
    echo "Error: Ghostty source not found at $GHOSTTY_DIR"
    echo "Set GHOSTTY_SOURCE_DIR to the path of your ghostty checkout."
    exit 1
fi

GHOSTTY_SHA="$(git -C "$GHOSTTY_DIR" rev-parse HEAD)"
CACHE_ROOT="${FINITE_CACHE_DIR:-$HOME/.cache/finite/ghosttykit}"
CACHE_DIR="$CACHE_ROOT/$GHOSTTY_SHA"
CACHE_XCFRAMEWORK="$CACHE_DIR/GhosttyKit.xcframework"
LOCAL_XCFRAMEWORK="$GHOSTTY_DIR/macos/GhosttyKit.xcframework"

mkdir -p "$CACHE_ROOT"

echo "==> Ghostty commit: $GHOSTTY_SHA"

if [ -d "$CACHE_XCFRAMEWORK" ]; then
    echo "==> Reusing cached GhosttyKit.xcframework"
else
    if [ -d "$LOCAL_XCFRAMEWORK" ]; then
        echo "==> Seeding cache from existing local GhosttyKit.xcframework"
    else
        XCFW_TARGET="${GHOSTTYKIT_TARGET:-universal}"
        echo "==> Building GhosttyKit.xcframework (target=$XCFW_TARGET, this may take a few minutes)..."
        (
            cd "$GHOSTTY_DIR"
            zig build -Demit-xcframework=true -Dxcframework-target="$XCFW_TARGET" -Doptimize=ReleaseFast
        )
    fi

    if [ ! -d "$LOCAL_XCFRAMEWORK" ]; then
        echo "Error: GhosttyKit.xcframework not found at $LOCAL_XCFRAMEWORK"
        exit 1
    fi

    mkdir -p "$CACHE_DIR"
    cp -R "$LOCAL_XCFRAMEWORK" "$CACHE_XCFRAMEWORK"
    echo "==> Cached GhosttyKit.xcframework at $CACHE_XCFRAMEWORK"
fi

echo "==> Creating symlink for GhosttyKit.xcframework..."
ln -sfn "$CACHE_XCFRAMEWORK" "$PROJECT_DIR/GhosttyKit.xcframework"

echo "==> Copying ghostty.h..."
cp "$GHOSTTY_DIR/include/ghostty.h" "$PROJECT_DIR/ghostty.h"

SHARE_DIR="$GHOSTTY_DIR/zig-out/share"

if [ -d "$SHARE_DIR" ]; then
    echo "==> Copying Ghostty resources (terminfo + shell-integration)..."
    mkdir -p "$PROJECT_DIR/Resources/terminfo"
    cp -R "$SHARE_DIR/terminfo/"* "$PROJECT_DIR/Resources/terminfo/"

    mkdir -p "$PROJECT_DIR/Resources/ghostty"
    cp -R "$SHARE_DIR/ghostty/shell-integration" "$PROJECT_DIR/Resources/ghostty/shell-integration"
elif [ -d "$PROJECT_DIR/Resources/terminfo" ] && [ -d "$PROJECT_DIR/Resources/ghostty" ]; then
    echo "==> Ghostty resources already present, skipping copy"
else
    echo "Error: zig-out/share not found and no existing resources in project"
    echo "Run 'cd $GHOSTTY_DIR && zig build' first to generate resources."
    exit 1
fi

echo "==> Setup complete!"
echo ""
echo "Open Finite.xcodeproj in Xcode and build."
