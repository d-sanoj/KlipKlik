#!/bin/bash
# Builds KlipKlick.app and packages it as a distributable .dmg.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/KlipKlick.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$ROOT/Resources/Info.plist" 2>/dev/null || echo 0.1.0)"
DMG="$ROOT/build/KlipKlick-$VERSION.dmg"

cd "$ROOT"

echo "==> Building app"
./Scripts/build_app.sh release

echo "==> Staging"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/KlipKlick.app"
# Drag-to-install target.
ln -s /Applications "$STAGING/Applications"

echo "==> Creating disk image"
rm -f "$DMG"
hdiutil create \
    -volname "KlipKlick $VERSION" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null

echo "==> Built $DMG"
ls -lh "$DMG" | awk '{print "    size: " $5}'
