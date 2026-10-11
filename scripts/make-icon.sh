#!/bin/bash
# Turn Resources/AppIcon.png (1024×1024) into an .icns at the given path.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$1"
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon.png --out "$SET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double Resources/AppIcon.png --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$OUT"
