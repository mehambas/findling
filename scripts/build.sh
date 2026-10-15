#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-module-cache"
build=(swift build --disable-sandbox --cache-path "$PWD/.build/cache" -c release --arch arm64 --arch x86_64)
"${build[@]}"
binary_dir="$("${build[@]}" --show-bin-path)"
app_path="$PWD/dist/Findling.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/Findling" "$app_path/Contents/MacOS/Findling"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"; fi
# An ad hoc signature changes with every build, and macOS then asks for folder access again.
# The self-signed certificate from scripts/make-certificate.sh keeps the identity stable;
# FINDLING_SIGN_IDENTITY picks another one, - forces ad hoc signing.
identity="${FINDLING_SIGN_IDENTITY:-$(security find-identity -p codesigning | awk -F'"' '$2 == "Findling Self-Signed" { print $2; exit }')}"
codesign --force --sign "${identity:--}" --identifier com.hamzabasaran.findling --timestamp=none "$app_path"
codesign --verify --strict "$app_path"
printf 'Built: %s (%s, signed: %s)\n' "$app_path" "$(lipo -archs "$app_path/Contents/MacOS/Findling")" "${identity:-ad hoc}"
