#!/bin/sh
# Makes the app's icon from one square PNG of at least 1024 × 1024 pixels: the ten sizes macOS wants (16 to 512
# points, at 1x and 2x) as app/Assets.xcassets/AppIcon.appiconset/icon_<size>x<size>[@2x].png, which gen.rb then
# adds to the app (the install script runs gen.rb). An Icon Composer document saved as app/AppIcon.icon is used
# instead when there is one; this script is not needed for it.
# Usage: scripts/make-app-icon.sh <icon.png>
set -eu
[ $# -eq 1 ] || { echo "usage: $0 <icon.png>" >&2; exit 2; }
src=$1
[ -f "$src" ] || { echo "make-app-icon: no such file: $src" >&2; exit 1; }
width=$(sips -g pixelWidth "$src" | awk '/pixelWidth/ { print $2 }')
height=$(sips -g pixelHeight "$src" | awk '/pixelHeight/ { print $2 }')
if [ "$width" != "$height" ] || [ "$width" -lt 1024 ]; then
    echo "make-app-icon: $src is $width × $height; it must be square and at least 1024 × 1024" >&2
    exit 1
fi
root=$(cd "$(dirname "$0")/.." && pwd)
dir=$root/app/Assets.xcassets/AppIcon.appiconset
for size in 16 32 128 256 512; do
    sips -s format png -z "$size" "$size" "$src" --out "$dir/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -s format png -z "$double" "$double" "$src" --out "$dir/icon_${size}x${size}@2x.png" >/dev/null
done
if [ -d "$root/app/AppIcon.icon" ]; then
    # gen.rb takes the Icon Composer document over the PNGs whenever it is there.
    echo "make-app-icon: wrote the ten sizes into $dir, but app/AppIcon.icon exists and the app uses it:" \
        "these PNGs are not used while it is there"
else
    echo "make-app-icon: wrote the ten sizes into $dir; run scripts/install-driver.sh to build and install the app with it"
fi
