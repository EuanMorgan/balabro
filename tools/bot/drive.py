#!/usr/bin/env python3
"""Plays a run with a fixed plan instead of Claude, to prove the bot's moments and buttons against the real game.

Usage: tools/bot/drive.py [timeout seconds]. Prints the bot's messages and exits 0 if the run reached an ending.
"""
import os, select, subprocess, sys, time

PLANS = {
    "shop": ["buy card 1", "buy card 2", "end:next play"],
    "pack": ["take pick 1", "end:next play"],
    "blind": ["end:next play"],
    "hand": ["end:next play"],
}

launch = os.path.join(os.path.dirname(os.path.abspath(__file__)), "launch.sh")
game = subprocess.Popen([launch], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
deadline = time.time() + float(sys.argv[1] if len(sys.argv) > 1 else 300)
start = time.time()
ending = None
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
        reply = "plan|" + parts[1] + "|" + "|".join(PLANS[parts[2]])
        game.stdin.write(reply + "\n")
        game.stdin.flush()
    elif parts[0] in ("ended", "broken"):
        ending = parts[0]
        break
game.stdin.close()
game.wait(timeout=20)
print("exit status", game.returncode, "ending", ending)
sys.exit(0 if ending == "ended" else 1)
