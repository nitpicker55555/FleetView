#!/usr/bin/env bash
# Regenerate AppIcon.icns from lighthouse.svg. macOS-only: uses qlmanage (SVG→PNG),
# sips (resize) and iconutil (iconset→icns), all stock. Run from anywhere.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SVG="$DIR/lighthouse.svg"
MASTER="$DIR/icon_1024.png"
SET="$DIR/AppIcon.iconset"
OUT="$DIR/AppIcon.icns"

echo "▸ Rendering $SVG → 1024px master"
TMP="$(mktemp -d)"
qlmanage -t -s 1024 -o "$TMP" "$SVG" >/dev/null 2>&1
mv "$TMP/lighthouse.svg.png" "$MASTER"
rm -rf "$TMP"

echo "▸ Building iconset"
rm -rf "$SET"; mkdir -p "$SET"
sips -z 16   16   "$MASTER" --out "$SET/icon_16x16.png"      >/dev/null
sips -z 32   32   "$MASTER" --out "$SET/icon_16x16@2x.png"   >/dev/null
sips -z 32   32   "$MASTER" --out "$SET/icon_32x32.png"      >/dev/null
sips -z 64   64   "$MASTER" --out "$SET/icon_32x32@2x.png"   >/dev/null
sips -z 128  128  "$MASTER" --out "$SET/icon_128x128.png"    >/dev/null
sips -z 256  256  "$MASTER" --out "$SET/icon_128x128@2x.png" >/dev/null
sips -z 256  256  "$MASTER" --out "$SET/icon_256x256.png"    >/dev/null
sips -z 512  512  "$MASTER" --out "$SET/icon_256x256@2x.png" >/dev/null
sips -z 512  512  "$MASTER" --out "$SET/icon_512x512.png"    >/dev/null
cp "$MASTER" "$SET/icon_512x512@2x.png"

echo "▸ iconutil → $OUT"
iconutil -c icns "$SET" -o "$OUT"
rm -rf "$SET"
echo "▸ Done: $OUT"
