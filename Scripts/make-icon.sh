#!/bin/sh
# Draws the app's icon with the app's own code and packs it into Support/AppIcon.icns, plus docs/icon.png for the
# README. Run it again only to change the icon: the result is kept in the repository.
set -e
cd "$(dirname "$0")/.."
swift build -c release
set_dir=$(mktemp -d)/AppIcon.iconset
mkdir -p "$set_dir"
"$(swift build -c release --show-bin-path)/LiquidMouse" --icon "$set_dir/full.png"
for size in 16 32 128 256 512; do
    sips -z $size $size "$set_dir/full.png" --out "$set_dir/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$set_dir/full.png" --out "$set_dir/icon_${size}x${size}@2x.png" >/dev/null
done
sips -z 256 256 "$set_dir/full.png" --out docs/icon.png >/dev/null
rm "$set_dir/full.png"
iconutil -c icns "$set_dir" -o Support/AppIcon.icns
echo Support/AppIcon.icns
