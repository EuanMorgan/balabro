#!/bin/zsh
# Usage: tools/bot/launch.sh
# Builds the bot's private copy of your installed Balatro and runs it with stdin and stdout attached, as Balabro does.
# It saves to its own LÖVE folder, so your real Balatro profile is never touched.
set -euo pipefail

BALATRO_APP=${BALATRO_APP:-"$HOME/Library/Application Support/Steam/steamapps/common/Balatro/Balatro.app"}
REPO=${0:A:h:h:h}
WORK=${TMPDIR:-/tmp}/balabro-bot-dev
GAME="$WORK/balabro-bot-dev"
RUNTIME="$WORK/Runtime.app"

if [[ ! -d "$RUNTIME" ]]; then
  mkdir -p "$GAME"
  unzip -q "$BALATRO_APP/Contents/Resources/Balatro.love" -d "$GAME"
  print 'require "bot/main"' >> "$GAME/main.lua"
  ditto "$BALATRO_APP" "$RUNTIME"
  rm "$RUNTIME/Contents/Resources/Balatro.love"
fi
rm -rf "$GAME/bot"
mkdir -p "$GAME/bot"
cp "$REPO"/bot/*.lua "$REPO"/tools/bot/verify.lua "$GAME/bot/"
SDL_MAC_BACKGROUND_APP=1 exec "$RUNTIME/Contents/MacOS/love" "$GAME"
