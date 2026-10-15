#!/bin/bash
# Sets the version, builds and signs Findling, and packs it into dist/Findling-<version>.dmg.
# Usage: scripts/release.sh <version>
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?Usage: scripts/release.sh <version>, for example 0.2.0}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "The version must look like 1.2.3." >&2; exit 1; }
# Without the certificate every release would be a different app to macOS and lose its folder permissions.
security find-identity -p codesigning | grep -qF '"Findling Self-Signed"' || { echo "\"Findling Self-Signed\" is not in the keychain (see scripts/make-certificate.sh)." >&2; exit 1; }

plist=Resources/Info.plist
build_number=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist") + 1 ))
perl -pi -e "s{(<key>CFBundleShortVersionString</key><string>)[^<]*}{\${1}$version}; s{(<key>CFBundleVersion</key><string>)[^<]*}{\${1}$build_number}" "$plist"
FINDLING_SIGN_IDENTITY="Findling Self-Signed" bash scripts/build.sh

dmg="dist/Findling-$version.dmg"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto dist/Findling.app "$staging/Findling.app"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -ov -volname "Findling" -srcfolder "$staging" -fs HFS+ -format UDZO "$dmg"
hdiutil verify -quiet "$dmg"
printf 'Release %s (build %s): %s, %s\nSHA-256 %s\n' "$version" "$build_number" "$dmg" "$(du -h "$dmg" | cut -f1)" "$(shasum -a 256 "$dmg" | cut -d' ' -f1)"
