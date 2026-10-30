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
cp "$root/Packaging/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp -R "$root/bot" "$app/Contents/Resources/bot"

# There is no Developer ID, so Gatekeeper blocks the download until the user clicks Open Anyway in
# Privacy & Security, as the README explains. Releases must use the certificate from
# make-signing-identity.sh, or users lose Screen Recording on update. Ad-hoc is for other people's builds.
signing="$HOME/.balabro-signing"
if [ -f "$signing/signing.keychain-db" ]; then
    security unlock-keychain -p "$(cat "$signing/password")" "$signing/signing.keychain-db"
    identity="$(security find-certificate -c Balabro -Z "$signing/signing.keychain-db" | awk '/SHA-1/{print $3}')"
    codesign --force --sign "$identity" --keychain "$signing/signing.keychain-db" --timestamp=none "$app"
else
    codesign --force --sign - --timestamp=none "$app"
fi
codesign --verify --strict "$app"

# ditto keeps the signature's extended attributes, which `zip` drops.
ditto -c -k --keepParent "$app" "$root/dist/Balabro-$version.zip"
echo "$root/dist/Balabro-$version.zip"
