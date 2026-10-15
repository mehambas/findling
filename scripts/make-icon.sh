#!/bin/bash
# Turns a 1024 × 1024 PNG into Resources/AppIcon.icns, which scripts/build.sh copies into the app.
set -euo pipefail
cd "$(dirname "$0")/.."
source="${1:?Usage: scripts/make-icon.sh <1024 × 1024 PNG>}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
iconset="$work/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$source" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$source" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
