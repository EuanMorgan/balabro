#!/usr/bin/env python3
"""Plays the Windows app's part against balabro-engine, to check the engine end to end from a terminal.

Usage: tools/engine/wire.py <balabro-engine> <saves root>

Waits for advice on the save, asks a follow-up, answers the screenshot request with no image, waits for the
reply, then closes stdin and checks the engine exits. Each line from the engine is printed, shortened, except
the many sent while Claude streams its answer.
Spends two Claude Opus turns.
"""
import json
import queue
import subprocess
import sys
import threading
import time

engine, saves = sys.argv[1], sys.argv[2]
proc = subprocess.Popen([engine, "--saves-root", saves], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, encoding="utf-8")
lines = queue.Queue()
threading.Thread(target=lambda: [lines.put(line) for line in proc.stdout] + [lines.put(None)], daemon=True).start()
start = time.time()


def show(message):
    view = message.get("view", {})
    summary = {key: message[key] for key in ("version", "fontPath", "id") if key in message}
    summary.update({key: view[key] for key in ("status", "headline", "title") if key in view})
    if view.get("advice", {}).get("doNow"):
        summary["doNow"] = view["advice"]["doNow"]
    if view.get("thread"):
        summary["thread"] = [(f["question"], f["reply"][:100]) for f in view["thread"]]
    if "problem" in view:
        summary["problem"] = view["problem"]["message"]
    print(f"{time.time() - start:6.1f}s {message['type']} {json.dumps(summary, ensure_ascii=False)}", flush=True)


def send(message):
    print(f"{time.time() - start:6.1f}s SEND {json.dumps(message)}", flush=True)
    proc.stdin.write(json.dumps(message) + "\n")
    proc.stdin.flush()


def until(done, limit=300):
    deadline = time.time() + limit
    while time.time() < deadline:
        try:
            line = lines.get(timeout=deadline - time.time())
        except queue.Empty:
            break
        if line is None:
            sys.exit("engine closed stdout")
        message = json.loads(line)
        if message["type"] == "capture":
            show(message)
            send({"type": "screenshot", "id": message["id"], "png": None})
            continue
        if message["type"] != "coach" or message["view"]["status"] != "answering":
            show(message)
        if done(message):
            return
    sys.exit("timed out")


def coach_ready(test):
    return lambda m: m["type"] == "coach" and m["view"]["status"] == "ready" and test(m["view"])


until(coach_ready(lambda v: v.get("advice", {}).get("doNow")))
send({"type": "ask", "question": "why?"})
until(coach_ready(lambda v: v["thread"] and v["thread"][-1]["reply"]))
proc.stdin.close()
print(f"{time.time() - start:6.1f}s stdin closed, engine exited with {proc.wait(timeout=30)}", flush=True)
