#!/bin/bash
# Builds KlipKlick and assembles KlipKlick.app.
#
# There is no Xcode project here on purpose: this machine has only the Command
# Line Tools, so SwiftPM compiles the binary and this script wraps it in the
# bundle layout macOS expects.
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/KlipKlick.app"

cd "$ROOT"

echo "==> Building ($CONFIGURATION)"
swift build -c "$CONFIGURATION"
BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/KlipKlick"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/KlipKlick"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Rebuild the .icns whenever the artwork is newer, so the icon is never stale
# and the generated file does not need committing.
if [ -f "$ROOT/Resources/AppIcon.png" ] \
   && [ ! "$ROOT/Resources/AppIcon.icns" -nt "$ROOT/Resources/AppIcon.png" ]; then
    "$ROOT/Scripts/make_icon.sh" >/dev/null
fi

# The icon is optional: the app builds and runs without one, it just shows the
# generic bundle icon until artwork is dropped at Resources/AppIcon.png.
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "    (no Resources/AppIcon.icns — run Scripts/make_icon.sh to build one)"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# macOS needs *some* signature to hang the Accessibility permission on. An ad-hoc
# signature is derived from the binary's own contents, so it changes on every
# rebuild and silently revokes that permission — use Preferences ▸ Shortcuts ▸
# "Reset permission" afterwards to clear the stale grant and re-approve.
#
# Set KLIPKLICK_SIGN_IDENTITY to a real code-signing identity to make the grant
# survive rebuilds.
IDENTITY="${KLIPKLICK_SIGN_IDENTITY:-}"

if [ -n "$IDENTITY" ] && security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
    echo "==> Signing as '$IDENTITY'"
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "==> Signing (ad-hoc)"
    codesign --force --sign - "$APP"
fi

echo "==> Built $APP"
