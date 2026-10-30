#!/bin/zsh
# Usage: tools/driver/run.sh [output-dir]
# Plays a scripted run with your installed Balatro and writes every save.jkr it makes to output-dir.
# Saves go to a separate LÖVE folder, so your real Balatro profile is never touched.
set -euo pipefail

BALATRO_APP=${BALATRO_APP:-"$HOME/Library/Application Support/Steam/steamapps/common/Balatro/Balatro.app"}
OUT=${1:-/tmp/balabro-driver-out}
WORK=${TMPDIR:-/tmp}/balabro-driver
GAME="$WORK/balabro-driver-game"
RUNTIME="$WORK/LoveRuntime.app"
SAVE_DIR="$HOME/Library/Application Support/LOVE/balabro-driver-game"

rm -rf "$WORK" "$SAVE_DIR"
mkdir -p "$GAME" "$OUT"
rm -f "$OUT"/*.jkr(N) "$OUT"/*.png(N)
unzip -q "$BALATRO_APP/Contents/Resources/Balatro.love" -d "$GAME"
cp "${0:A:h}/driver.lua" "$GAME/driver.lua"
print 'require "driver"' >> "$GAME/main.lua"

# A runtime with no Balatro.love inside, so LÖVE runs the unpacked folder instead of the shipped game.
ditto "$BALATRO_APP" "$RUNTIME"
rm "$RUNTIME/Contents/Resources/Balatro.love"

BALABRO_DRIVER_OUT="$OUT" "$RUNTIME/Contents/MacOS/love" "$GAME"
print "Saves in $OUT, live save folder $SAVE_DIR"
