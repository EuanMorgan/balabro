#!/usr/bin/env python3
"""Plays a run with a fixed plan instead of Claude, to prove the bot's moments and buttons against the real game.

Usage: tools/bot/drive.py [timeout seconds]. Prints the bot's messages and exits 0 if the run reached an ending.
"""
import os, select, subprocess, sys, time

PLANS = {
    "shop": ["buy card 1", "buy card 2", "end:open 1"],
    "shop again": ["end:next play"],
    "pack": ["take pick 1", "end:next play"],
    "blind": ["end:next play"],
    "hand": ["end:next play"],
}

launch = os.path.join(os.path.dirname(os.path.abspath(__file__)), "launch.sh")
game = subprocess.Popen([launch], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
deadline = time.time() + float(sys.argv[1] if len(sys.argv) > 1 else 300)
start = time.time()
ending = None
opened_pack = False
while time.time() < deadline:
    if not select.select([game.stdout], [], [], 1)[0]:
        continue
    line = game.stdout.readline()
    if not line:
        break
    if not line.startswith("@@"):
        continue
    parts = line[2:].rstrip("\n").split("|")
    print(f"{time.time() - start:7.1f} {line[2:].rstrip()}", flush=True)
    if parts[0] == "decide":
        kind = parts[2]
        if kind == "shop" and opened_pack:
            kind = "shop again"
        opened_pack = parts[2] == "shop" and not opened_pack
        reply = "plan|" + parts[1] + "|" + "|".join(PLANS[kind])
        game.stdin.write(reply + "\n")
        game.stdin.flush()
    elif parts[0] in ("ended", "broken"):
        ending = parts[0]
        break
game.stdin.close()
game.wait(timeout=20)
print("exit status", game.returncode, "ending", ending)
sys.exit(0 if ending == "ended" else 1)
