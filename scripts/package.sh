#!/bin/bash
# Build build/Rozmova.app and build/Rozmova-<version>.dmg. Used by the release workflow and
# works locally too: ./scripts/package.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Rozmova"

APP=build/Rozmova.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Rozmova"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
./scripts/make-icon.sh "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc unless an identity is given; a Developer ID would also need notarization.
codesign --force --sign "${ROZMOVA_SIGN_IDENTITY:--}" "$APP"

# The disk image: the app and a shortcut to Applications to drag it onto.
STAGE=build/dmg
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Rozmova" -srcfolder "$STAGE" -ov -format UDZO "build/Rozmova-$VERSION.dmg"
echo "Built: build/Rozmova-$VERSION.dmg"
