#!/bin/bash
# Builds dist/Balabro.app and dist/Balabro-<version>.zip from SwiftPM alone (no Xcode project).
# Usage: scripts/make-app.sh 0.1.0
# Publishing is a separate, manual step:
#   gh release create v0.1.0 dist/Balabro-0.1.0.zip --title "Balabro 0.1.0" --notes-file design/release-notes.md
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

# Ad-hoc: there is no Developer ID on this machine. Gatekeeper blocks the download until the user
# runs `xattr -dr com.apple.quarantine Balabro.app` (the release notes say so).
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict "$app"

# ditto keeps the signature's extended attributes, which `zip` drops.
ditto -c -k --keepParent "$app" "$root/dist/Balabro-$version.zip"
echo "$root/dist/Balabro-$version.zip"
