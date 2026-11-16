#!/bin/sh
# Package an already-built app. A notarized release requires a configured Keychain profile and Developer ID.
set -eu
cd "$(dirname "$0")/.."
tag=${1:?Usage: Scripts/package-release.sh <tag>, for example v0.9.0-beta.1}
case "$tag" in *[!A-Za-z0-9._-]*|'') echo "Invalid release tag" >&2; exit 2 ;; esac
app=build/LiquidMouse.app
codesign --verify --deep --strict "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
case "$tag" in "v$version"|"v$version-"*) ;; *) echo "Tag does not match app version $version" >&2; exit 2 ;; esac
folder="build/releases/$tag"
mkdir -p "$folder"
archive="$folder/LiquidMouse-$tag.zip"
if [ -n "${NOTARY_PROFILE:-}" ]; then
    if ! codesign -dv "$app" 2>&1 | grep -q 'Authority=Developer ID Application:'; then
        echo "Notarization requires a Developer ID Application signature." >&2
        exit 1
    fi
    ditto -c -k --keepParent "$app" "$folder/submission.zip"
    xcrun notarytool submit "$folder/submission.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=2 "$app"
    rm "$folder/submission.zip"
fi
ditto -c -k --keepParent "$app" "$archive"
cp "$archive" build/LiquidMouse.zip
(cd "$folder" && shasum -a 256 "LiquidMouse-$tag.zip" > SHA256SUMS)
codesign -dv --verbose=2 "$app" 2> "$folder/signature.txt"
printf '%s\n' "$archive"
