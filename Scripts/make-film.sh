#!/bin/sh
# Makes the launch film with the app's own drawing code: build/LiquidMouse.mp4 in English, build/LiquidMouse-it.mp4
# in Italian, and docs/demo.gif, the README's animation. Needs ffmpeg (brew install ffmpeg).
set -e
cd "$(dirname "$0")/.."
swift build -c release
mkdir -p build
binary="$(swift build -c release --show-bin-path)/LiquidMouse"
# The frames come raw: 1920x1080 RGBA, 60 a second (see Film.swift).
for language in en it; do
    name=LiquidMouse; [ "$language" = it ] && name=LiquidMouse-it
    "$binary" --film "$language" |
        ffmpeg -y -loglevel error -f rawvideo -pix_fmt rgba -s 1920x1080 -r 60 -i - \
            -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p -movflags +faststart "build/$name.mp4"
done
# The README's animation: the film from its title to the end of the typing, drawn again as a GIF needs it, 50 frames
# a second on plain paper. It is put in a loop's order: it starts on the finished title and ends with the title being
# written. The first frame, which is all some readers see, then says what this is, and the loop has no seam.
"$binary" --film gif |
    ffmpeg -y -loglevel error -f rawvideo -pix_fmt rgba -s 1920x1080 -r 50 -i - -filter_complex \
        "scale=800:-1:flags=lanczos,split[a][b];[a]trim=5:23.6,setpts=PTS-STARTPTS[rest];[b]trim=4:5,setpts=PTS-STARTPTS[title];[rest][title]concat" \
        -c:v ffv1 build/demo.mkv
# Few colors and no dithering: a GIF stays small where neighboring pixels are the same, and looks clean there too.
ffmpeg -y -loglevel error -i build/demo.mkv -vf palettegen=max_colors=128:stats_mode=diff -update 1 build/demo-palette.png
ffmpeg -y -loglevel error -i build/demo.mkv -i build/demo-palette.png \
    -filter_complex "[0:v][1:v]paletteuse=dither=none:diff_mode=rectangle" docs/demo.gif
ls -l build/LiquidMouse.mp4 build/LiquidMouse-it.mp4 docs/demo.gif
