#!/bin/bash
# Builds Resources/AppIcon.icns from Resources/AppIcon.png.
#
# Drop a square PNG (1024×1024 is ideal) at Resources/AppIcon.png and run this.
# The corners are rounded first, then every size macOS asks for is rendered and
# packed into the .icns. build_app.sh copies the result into the bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/Resources/AppIcon.png"
OUT="$ROOT/Resources/AppIcon.icns"
# Fraction of the icon's width. macOS's own squircle is ~0.22; this is gentler.
RADIUS="${KLIPKLICK_ICON_RADIUS:-0.18}"

if [ ! -f "$SOURCE" ]; then
    echo "No $SOURCE — save the artwork there first (square PNG, 1024×1024)." >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

echo "==> Rounding corners (r = $RADIUS × width)"
swift "$ROOT/Scripts/RoundIcon.swift" "$SOURCE" "$WORK/rounded.png" "$RADIUS"

echo "==> Rendering sizes"
# 1x and 2x for each size the iconset format expects.
for size in 16 32 128 256 512; do
    sips -z $size $size "$WORK/rounded.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$WORK/rounded.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

echo "==> Packing .icns"
iconutil --convert icns "$ICONSET" --output "$OUT"
echo "==> Built $OUT ($(du -h "$OUT" | cut -f1))"
