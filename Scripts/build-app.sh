#!/bin/sh
# Builds build/LiquidMouse.app, a real app bundle, so that macOS grants permissions to LiquidMouse itself rather
# than to whatever launched it, and build/LiquidMouse.zip to hand it on. One binary for Apple silicon and Intel
# Macs. Signed ad hoc: it runs anywhere, but macOS asks the user to allow it the first time (see the README).
#
#   Scripts/build-app.sh            build only
#   Scripts/build-app.sh --install  also put it in /Applications, replacing the copy there
set -eu
cd "$(dirname "$0")/.."
case "${1:-}" in
    ""|--install) ;;
    *) echo "Usage: Scripts/build-app.sh [--install]" >&2; exit 2 ;;
esac
# Each architecture in a folder of its own: they would otherwise land in the same place.
for arch in arm64 x86_64; do
    swift build -c release --triple "$arch-apple-macosx15.0" --scratch-path ".build/$arch"
done
app=build/LiquidMouse.app
binary="$app/Contents/MacOS/LiquidMouse"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lipo -create -output "$binary" \
    "$(swift build -c release --triple arm64-apple-macosx15.0 --scratch-path .build/arm64 --show-bin-path)/LiquidMouse" \
    "$(swift build -c release --triple x86_64-apple-macosx15.0 --scratch-path .build/x86_64 --show-bin-path)/LiquidMouse"
# macOS gives an app the windows and controls of the SDK its binary says it was built with, and the toolchains
# disagree: the Command Line Tools record the deployment target, Xcode its own SDK, which on macOS 26 and later
# turns the settings panel translucent and hard to read. Recording the deployment target makes every build look
# and behave like the ones that were tested. vtool warns about the signature; the app is signed below.
vtool -set-build-version macos 15.0 15.0 -replace -output "$binary" "$binary"
cp Support/Info.plist "$app/Contents/"
cp Support/AppIcon.icns "$app/Contents/Resources/"
cp LICENSE "$app/Contents/Resources/LICENSE"
cp -R Support/en.lproj Support/it.lproj "$app/Contents/Resources/"
# Set SIGNING_IDENTITY to a Developer ID Application identity for distribution.
# Without it the app is signed ad hoc, which is enough for builds from source and for betas.
if [ "${SIGNING_IDENTITY:--}" = - ]; then
    codesign --force --sign - "$app"
else
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$app"
fi
codesign --verify --deep --strict "$app"
# A zip that keeps the app's signature and permissions intact.
rm -f build/LiquidMouse.zip
ditto -c -k --keepParent "$app" build/LiquidMouse.zip
if [ "${1:-}" = "--install" ]; then
    # Installed in Applications: run from the project folder, which may be in Documents, macOS would ask for
    # access to that folder.
    if pgrep -x LiquidMouse >/dev/null; then
        echo "Quit LiquidMouse before installing. The built app is ready in build/." >&2
        exit 1
    fi
    stage=$(mktemp -d /Applications/.LiquidMouse-install.XXXXXX)
    ditto "$app" "$stage/LiquidMouse.app"
    codesign --verify --deep --strict "$stage/LiquidMouse.app"
    if [ -d /Applications/LiquidMouse.app ]; then
        backup="build/backups/LiquidMouse-$(date +%Y%m%d-%H%M%S).app"
        mkdir -p build/backups
        ditto /Applications/LiquidMouse.app "$backup"
        codesign --verify --deep --strict "$backup"
        mv /Applications/LiquidMouse.app "$stage/previous.app"
        echo "Previous version: $backup"
    fi
    if ! mv "$stage/LiquidMouse.app" /Applications/LiquidMouse.app; then
        if [ -d "$stage/previous.app" ]; then mv "$stage/previous.app" /Applications/LiquidMouse.app; fi
        exit 1
    fi
    rm -rf "$stage"
    echo /Applications/LiquidMouse.app
else
    echo "$app"
fi
