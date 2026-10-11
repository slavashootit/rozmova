#!/bin/bash
# Installs the latest Rozmova release into /Applications:
#   curl -fsSL https://slavashootit.github.io/rozmova/install.sh | bash
set -euo pipefail

URL="https://github.com/slavashootit/rozmova/releases/latest/download/Rozmova.dmg"
APP=/Applications/Rozmova.app

if [ "$(uname -m)" != arm64 ]; then
    echo "Rozmova працює лише на Mac з Apple Silicon (M1 і новіші)." >&2
    exit 1
fi
if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 14 ]; then
    echo "Rozmova потребує macOS 14 Sonoma або новішу." >&2
    exit 1
fi

TMP="$(mktemp -d)"
cleanup() {
    hdiutil detach -quiet "$TMP/mnt" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

echo "Завантажую Rozmova…"
curl -fL --progress-bar "$URL" -o "$TMP/Rozmova.dmg"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$TMP/mnt" "$TMP/Rozmova.dmg"

pkill -x Rozmova 2>/dev/null && sleep 1 || true
rm -rf "$APP"
ditto "$TMP/mnt/Rozmova.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

open "$APP"
echo "Готово: Rozmova у «Програмах», іконка з хвилькою вже в рядку меню."
