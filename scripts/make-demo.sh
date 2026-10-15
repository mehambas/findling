#!/bin/bash
# Renders the README animations from sample files into docs/images/demo-dark.gif and demo-light.gif.
# Needs ffmpeg and a build from scripts/build.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
width="${1:-960}"
frames="$(mktemp -d)"
trap 'rm -rf "$frames"' EXIT
dist/Findling.app/Contents/MacOS/Findling --capture-demo "$frames"
mkdir -p docs/images
for appearance in dark light; do
    ffmpeg -loglevel error -y -f concat -i "$frames/$appearance/frames.txt" \
        -vf "scale=$width:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=full[p];[b][p]paletteuse=dither=sierra2_4a" \
        -fps_mode vfr -loop 0 "docs/images/demo-$appearance.gif"
done
ls -lh docs/images/demo-*.gif
