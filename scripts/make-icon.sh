#!/bin/bash
# Builds Resources/AppIcon.icns from Resources/Icon: the simplified artwork fills the 16 and 32 px slots,
# the full artwork everything larger. macOS 14 and 15 show it.
# Compiles Resources/AppIcon.icon into Resources/Assets.car for macOS 26 and later, which derive the
# dark, tinted and clear styles from it. That needs Xcode 26 or later; the results are committed so
# that building the app does not.
set -euo pipefail
cd "$(dirname "$0")/.."
icon=Resources/Icon
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
iconset="$work/AppIcon.iconset"
mkdir "$iconset"
cp "$icon/Findling-16.png" "$iconset/icon_16x16.png"
cp "$icon/Findling-32.png" "$iconset/icon_16x16@2x.png"
cp "$icon/Findling-32.png" "$iconset/icon_32x32.png"
for slot in 32x32@2x:64 128x128:128 128x128@2x:256 256x256:256 256x256@2x:512 512x512:512; do
    sips -z "${slot#*:}" "${slot#*:}" "$icon/Findling-1024.png" --out "$iconset/icon_${slot%:*}.png" >/dev/null
done
cp "$icon/Findling-1024.png" "$iconset/icon_512x512@2x.png"
iconutil -c icns "$iconset" -o Resources/AppIcon.icns
# actool writes its own, smaller AppIcon.icns next to Assets.car; only Assets.car is kept.
xcrun actool Resources/AppIcon.icon --compile "$work" --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --output-partial-info-plist "$work/partial.plist" --errors --warnings >/dev/null
cp "$work/Assets.car" Resources/Assets.car
sips -z 256 256 "$icon/Findling-1024.png" --out docs/images/icon.png >/dev/null
echo "Wrote Resources/AppIcon.icns, Resources/Assets.car and docs/images/icon.png"
