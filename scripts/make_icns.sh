#!/bin/bash
# Render the app icon and bake Sauron.icns (no Xcode).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-.build/Sauron.icns}"
WORK="$(mktemp -d /tmp/sauron-icon.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

MASTER="$WORK/master.png"
swift scripts/make_icon.swift "$MASTER" 1024 > /dev/null

ICONSET="$WORK/Sauron.iconset"
mkdir -p "$ICONSET"
for entry in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
             128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 \
             512:icon_256x256@2x 512:icon_512x512 1024:icon_512x512@2x; do
    size="${entry%%:*}"
    name="${entry#*:}"
    sips -z "$size" "$size" "$MASTER" --out "$ICONSET/$name.png" > /dev/null
done

mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$ICONSET" -o "$OUT"
echo "wrote $OUT"
