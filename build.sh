#!/bin/bash
# Build Rozmova.app from the Swift package, install it to ~/Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Rozmova"

APP=build/Rozmova.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Rozmova"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
./scripts/make-icon.sh "$APP/Contents/Resources/AppIcon.icns"

# A stable signing identity keeps the Microphone and Screen Recording permissions across rebuilds.
# Ad-hoc signing changes the signature every build, so macOS asks for them again.
# Order: $ROZMOVA_SIGN_IDENTITY, an "Apple Development" cert, self-signed "Rozmova Dev" or "Bufer Dev".
IDENTITY="${ROZMOVA_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development/ && !found { print $2; found = 1 }' || true)"
fi
for NAME in "Rozmova Dev" "Bufer Dev"; do
    if [ -z "$IDENTITY" ] && security find-certificate -c "$NAME" >/dev/null 2>&1; then
        IDENTITY="$NAME"
    fi
done
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Signed with: $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "Signed ad-hoc: after each rebuild macOS may ask for Microphone and Screen Recording again."
    echo "To fix for good, create a 'Rozmova Dev' code signing certificate (see README)."
fi

# Quit the running copy and wait until it is gone, otherwise `open` fails with -600.
pkill -x Rozmova 2>/dev/null || true
for _ in $(seq 1 50); do
    pgrep -x Rozmova >/dev/null || break
    sleep 0.1
done

# Install where the app already lives: /Applications if it was moved there, else ~/Applications.
if [ -d /Applications/Rozmova.app ]; then
    DEST=/Applications
else
    DEST="$HOME/Applications"
fi
mkdir -p "$DEST"
rm -rf "$DEST/Rozmova.app"
cp -R "$APP" "$DEST/"
open "$DEST/Rozmova.app" || { sleep 1; open "$DEST/Rozmova.app"; }
echo "Installed: $DEST/Rozmova.app"
