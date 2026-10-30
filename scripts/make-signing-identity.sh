#!/bin/bash
# Creates the self-signed certificate that make-app.sh signs with, once per build machine.
# macOS ties Screen Recording permission to the signature. Ad-hoc signatures change with every build,
# which silently loses the permission. A fixed certificate keeps it across updates.
# It lives in its own keychain, so the login keychain isn't touched and signing never shows a prompt.
# Losing this folder only means everyone grants the permission once more.
set -euo pipefail
dir="$HOME/.balabro-signing"
keychain="$dir/signing.keychain-db"
[ -f "$keychain" ] && { echo "Already exists: $keychain"; exit 0; }

mkdir -p "$dir"
chmod 700 "$dir"
password="$(/usr/bin/openssl rand -hex 24)"
printf '%s' "$password" > "$dir/password"
chmod 600 "$dir/password"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=Balabro" \
    -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -passout "pass:$password" -out "$work/identity.p12" 2>/dev/null

searchList="$(security list-keychains -d user | tr -d '"')"
security create-keychain -p "$password" "$keychain"
security set-keychain-settings "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$work/identity.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain" >/dev/null
# create-keychain can add itself to the user's search list. Put the list back as it was.
# shellcheck disable=SC2086
security list-keychains -d user -s $searchList
echo "Created $keychain"
