#!/bin/bash
# Builds dist/Balabro.app and dist/Balabro-<version>.zip from SwiftPM alone (no Xcode project).
# Usage: scripts/make-app.sh 0.1.0
# Publishing is a separate step: gh release create v<version> dist/Balabro-<version>.zip
set -euo pipefail
version="${1:?usage: make-app.sh <version>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/dist/Balabro.app"

swift build -c release --arch arm64 --arch x86_64 --package-path "$root"
bin="$(swift build -c release --arch arm64 --arch x86_64 --package-path "$root" --show-bin-path)"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Balabro" "$app/Contents/MacOS/Balabro"
sed "s/__VERSION__/$version/g" "$root/Packaging/Info.plist" > "$app/Contents/Info.plist"

# Ad-hoc, because there is no Developer ID. Gatekeeper blocks the download until the user clicks
# Open Anyway in Privacy & Security, as the README explains.
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict "$app"

# ditto keeps the signature's extended attributes, which `zip` drops.
ditto -c -k --keepParent "$app" "$root/dist/Balabro-$version.zip"
echo "$root/dist/Balabro-$version.zip"
