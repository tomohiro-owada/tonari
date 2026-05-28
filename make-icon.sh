#!/usr/bin/env bash
# Generate Resources/AppIcon.icns from a 1024x1024 source PNG.
#
# Usage: ./make-icon.sh <source-1024.png>
set -euo pipefail

SRC="${1:?Pass path to a 1024x1024 PNG as the first argument}"
if [[ ! -f "$SRC" ]]; then
    echo "Source not found: $SRC" >&2
    exit 1
fi

cd "$(dirname "$0")"
mkdir -p Resources
ICONSET="Resources/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# Apple iconset sizes (size:filename)
SIZES=(
    "16:icon_16x16.png"
    "32:icon_16x16@2x.png"
    "32:icon_32x32.png"
    "64:icon_32x32@2x.png"
    "128:icon_128x128.png"
    "256:icon_128x128@2x.png"
    "256:icon_256x256.png"
    "512:icon_256x256@2x.png"
    "512:icon_512x512.png"
    "1024:icon_512x512@2x.png"
)

for entry in "${SIZES[@]}"; do
    size="${entry%%:*}"
    name="${entry##*:}"
    sips -z "$size" "$size" "$SRC" --out "$ICONSET/$name" >/dev/null
done

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
rm -rf "$ICONSET"

echo "Generated: Resources/AppIcon.icns"
