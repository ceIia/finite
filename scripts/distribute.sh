#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
FINITE_DIR="$ROOT_DIR/Finite"
ENV_FILE="$ROOT_DIR/.env.release"
CERT="B38BF936E7A2BDD72ACAD34DC33AE1353A8EF33B"
ENTITLEMENTS="$FINITE_DIR/Resources/Finite.entitlements"

red()   { printf "\033[1;31m%s\033[0m\n" "$*"; }
green() { printf "\033[1;32m%s\033[0m\n" "$*"; }
bold()  { printf "\033[1m%s\033[0m\n" "$*"; }

die() { red "Error: $*"; exit 1; }

# ── Pre-flight checks ─────────────────────────────────────────────

bold "==> Pre-flight checks..."

# On main?
BRANCH=$(git -C "$ROOT_DIR" branch --show-current)
[ "$BRANCH" = "main" ] || die "Not on main (on $BRANCH)"

# Clean working tree?
if ! git -C "$ROOT_DIR" diff --quiet || ! git -C "$ROOT_DIR" diff --cached --quiet; then
    die "Working tree is dirty. Commit or stash changes first."
fi

# Up to date with remote?
git -C "$ROOT_DIR" fetch origin main --quiet
LOCAL=$(git -C "$ROOT_DIR" rev-parse HEAD)
REMOTE=$(git -C "$ROOT_DIR" rev-parse origin/main)
[ "$LOCAL" = "$REMOTE" ] || die "Local main ($LOCAL) differs from origin/main ($REMOTE). Push or pull first."

# Env file exists?
[ -f "$ENV_FILE" ] || die ".env.release not found"

# Signing identity available?
security find-identity -v -p codesigning 2>&1 | grep -q "$CERT" || die "Signing certificate not found in keychain"

green "  All checks passed."

# ── Version ────────────────────────────────────────────────────────

CURRENT_VERSION=$(grep 'MARKETING_VERSION' "$FINITE_DIR/Finite.xcodeproj/project.pbxproj" | head -1 | sed 's/.*= //;s/;.*//')
bold "  Current version: $CURRENT_VERSION"
printf "  Enter new version (e.g. 0.1.1): "
read -r VERSION
[ -n "$VERSION" ] || die "No version provided"

# Check tag doesn't exist
if git -C "$ROOT_DIR" tag -l "v$VERSION" | grep -q .; then
    die "Tag v$VERSION already exists"
fi

# ── Changelog ──────────────────────────────────────────────────────

bold "==> Writing changelog..."
LAST_TAG=$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null || echo "")
CHANGELOG_FILE=$(mktemp)

{
    echo "# Release notes for v$VERSION"
    echo "#"
    echo "# Lines starting with # are ignored."
    echo "# Save and close to continue. Empty file aborts."
    echo ""
    if [ -n "$LAST_TAG" ]; then
        git -C "$ROOT_DIR" log "$LAST_TAG"..HEAD --pretty=format:"- %s" --no-merges
    else
        git -C "$ROOT_DIR" log --pretty=format:"- %s" --no-merges -20
    fi
} > "$CHANGELOG_FILE"

${EDITOR:-vim} "$CHANGELOG_FILE"

# Strip comments and check if anything remains
NOTES=$(grep -v '^#' "$CHANGELOG_FILE" | sed '/^$/d')
rm "$CHANGELOG_FILE"
[ -n "$NOTES" ] || die "Empty changelog, aborting"

echo ""
bold "  Changelog:"
echo "$NOTES"
echo ""

# ── Confirm ────────────────────────────────────────────────────────

printf "  Release v%s? [y/N] " "$VERSION"
read -r CONFIRM
[ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ] || die "Aborted"

# ── Build ──────────────────────────────────────────────────────────

bold "==> Building release..."
cd "$FINITE_DIR"
xcodebuild -project Finite.xcodeproj -scheme Finite -configuration Release build 2>&1 | tail -3

APP=$(find ~/Library/Developer/Xcode/DerivedData -path "*/Finite-*/Build/Products/Release/Finite.app" -maxdepth 5 2>/dev/null | head -1)
[ -n "$APP" ] || die "Could not find built app"

# ── Stamp version ──────────────────────────────────────────────────

bold "==> Stamping version $VERSION..."
BUILD_NUMBER=$(git -C "$ROOT_DIR" rev-list --count HEAD)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

# ── Sign ───────────────────────────────────────────────────────────

bold "==> Signing Sparkle internals..."
codesign -f -s "$CERT" -o runtime --timestamp "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
codesign -f -s "$CERT" -o runtime --timestamp "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
codesign -f -s "$CERT" -o runtime --timestamp "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
codesign -f -s "$CERT" -o runtime --timestamp "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
codesign -f -s "$CERT" -o runtime --timestamp "$APP/Contents/Frameworks/Sparkle.framework"

bold "==> Signing app bundle..."
codesign -f -s "$CERT" -o runtime --timestamp --entitlements "$ENTITLEMENTS" "$APP"

bold "==> Verifying signature..."
codesign --verify --deep --strict "$APP"
green "  Signature valid."

# ── DMG ────────────────────────────────────────────────────────────

bold "==> Creating DMG..."
DMG_PATH="/tmp/Finite-${VERSION}.dmg"
hdiutil detach /Volumes/Finite 2>/dev/null || true
sleep 1
"$SCRIPT_DIR/create-dmg.sh" "$APP" /tmp

# ── Notarize ───────────────────────────────────────────────────────

bold "==> Notarizing (this may take a few minutes)..."
source "$ENV_FILE"

xcrun notarytool submit "$DMG_PATH" \
    --key "$APPLE_NOTARIZATION_KEY_PATH" \
    --key-id "$APPLE_NOTARIZATION_KEY_ID" \
    --issuer "$APPLE_NOTARIZATION_ISSUER" \
    --wait

bold "==> Stapling..."
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
green "  Notarization complete."

# ── Tag & Release ──────────────────────────────────────────────────

bold "==> Tagging v$VERSION..."
git -C "$ROOT_DIR" tag "v$VERSION"
git -C "$ROOT_DIR" push origin "v$VERSION"

bold "==> Creating GitHub release..."
PRERELEASE_FLAG=""
if [[ "$VERSION" == *-* ]]; then
    PRERELEASE_FLAG="--prerelease"
fi

gh release create "v${VERSION}" \
    --title "Finite v${VERSION}" \
    --notes "$NOTES" \
    $PRERELEASE_FLAG \
    "$DMG_PATH"

# ── Appcast ────────────────────────────────────────────────────────

if [[ "$VERSION" != *-* ]]; then
    bold "==> Updating appcast..."

    # Sign for Sparkle
    SPARKLE_SIG=$(echo "$SPARKLE_SIGNING_KEY" 2>/dev/null | sparkle-tools/bin/sign_update "$DMG_PATH" 2>/dev/null || echo "")

    DMG_SIZE=$(stat -f%z "$DMG_PATH")
    DATE=$(date -R)
    BUILD=$(git -C "$ROOT_DIR" rev-list --count HEAD)
    NOTES_HTML=$(echo "$NOTES" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/$/<br\/>/g')

    APPCAST_FILE=$(mktemp)
    cat > "$APPCAST_FILE" << APPCAST_EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Finite</title>
    <link>https://ceIia.github.io/finite/appcast.xml</link>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <description><![CDATA[$NOTES_HTML]]></description>
      <enclosure url="https://github.com/ceIia/finite/releases/download/v${VERSION}/Finite-${VERSION}.dmg"
        $SPARKLE_SIG
        length="$DMG_SIZE"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
APPCAST_EOF

    gh release upload "v${VERSION}" "$APPCAST_FILE#appcast.xml" --clobber

    # Update gh-pages
    GH_PAGES_DIR=$(mktemp -d)
    git clone --branch gh-pages --single-branch \
        "https://github.com/ceIia/finite.git" "$GH_PAGES_DIR" 2>/dev/null || {
        mkdir -p "$GH_PAGES_DIR" && cd "$GH_PAGES_DIR" && git init && git checkout -b gh-pages
        git remote add origin "https://github.com/ceIia/finite.git"
    }

    cp "$APPCAST_FILE" "$GH_PAGES_DIR/appcast.xml"
    cd "$GH_PAGES_DIR"
    git add appcast.xml
    git config user.name "$(git -C "$ROOT_DIR" config user.name)"
    git config user.email "$(git -C "$ROOT_DIR" config user.email)"
    git commit -m "Update appcast for v$VERSION" || true
    git push origin gh-pages
    rm -rf "$GH_PAGES_DIR"
    rm "$APPCAST_FILE"

    green "  Appcast updated."
fi

echo ""
green "==> v$VERSION released!"
echo "  https://github.com/ceIia/finite/releases/tag/v$VERSION"
