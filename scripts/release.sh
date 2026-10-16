#!/bin/bash
# Sets the version, builds and signs Findling, and packs it into dist/Findling.dmg with its checksum in dist/Findling.dmg.sha256.
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

# No version in the name: the README and the website link releases/latest/download/Findling.dmg,
# and the update check looks for the assets Findling.dmg and Findling.dmg.sha256.
dmg="dist/Findling.dmg"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto dist/Findling.app "$staging/Findling.app"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -ov -volname "Findling" -srcfolder "$staging" -fs HFS+ -format UDZO "$dmg"
hdiutil verify -quiet "$dmg"
(cd dist && shasum -a 256 Findling.dmg > Findling.dmg.sha256)
printf 'Release %s (build %s), attach both files to the v%s release:\n%s  %s\n%s  SHA-256 %s\n' "$version" "$build_number" "$version" \
    "$dmg" "$(du -h "$dmg" | cut -f1)" "$dmg.sha256" "$(cut -d' ' -f1 "$dmg.sha256")"
