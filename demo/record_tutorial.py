#!/usr/bin/env python3
"""Drive an nvim session through the annotation tutorial and record with asciinema."""

import os
import sys
import time

import pexpect

DEMO_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(DEMO_DIR)
CAST_FILE = os.path.join(DEMO_DIR, "annotation-tutorial.cast")
LAUNCH_SCRIPT = os.path.join(DEMO_DIR, "launch_nvim.sh")

# Clean up any previous audit data so the demo starts fresh
notes_json = os.path.join(REPO_ROOT, ".audit", "notes.json")
if os.path.exists(notes_json):
    os.remove(notes_json)


def slow_send(child, text, delay=0.06):
    """Send text character by character with a delay to simulate typing."""
    for ch in text:
        child.send(ch)
        time.sleep(delay)


def main():
    os.environ["TERM"] = "xterm-256color"
    os.environ["USER"] = "reviewer"

    child = pexpect.spawn(
        "asciinema",
        ["rec", "--overwrite", "-c", LAUNCH_SCRIPT, CAST_FILE],
        encoding="utf-8",
        dimensions=(35, 100),
        timeout=30,
    )

    # Wait for nvim to fully load and render the file
    time.sleep(4)

    # ── SCENE 1: Add an annotation ──────────────────────────────────────
    # Navigate to line 10 (the pbkdf2 hashing line)
    child.send("\x1b")  # Escape to ensure normal mode
    time.sleep(0.5)

    slow_send(child, ":10\r", delay=0.10)
    time.sleep(2)

    # Run :AuditAdd command
    slow_send(child, ":AuditAdd\r", delay=0.06)
    time.sleep(1.5)

    # Type the annotation text at the input prompt
    slow_send(child, "Consider using argon2 instead of pbkdf2 for better security", delay=0.04)
    time.sleep(0.8)
    child.send("\r")
    time.sleep(3)

    # ── SCENE 2: Edit the annotation ────────────────────────────────────
    # Dismiss any notification and ensure normal mode
    child.send("\x1b")
    time.sleep(1)

    # Run :AuditEdit command
    slow_send(child, ":AuditEdit\r", delay=0.06)
    time.sleep(2)

    # The edit prompt pre-fills old text. Ctrl-U clears cmd-line to left of cursor.
    child.send("\x15")  # Ctrl-U
    time.sleep(0.5)

    # Type new annotation text
    slow_send(
        child,
        r"TODO: migrate to argon2id -- pbkdf2 is outdated\nSee: OWASP password cheatsheet",
        delay=0.04,
    )
    time.sleep(0.8)
    child.send("\r")
    time.sleep(3)

    # ── SCENE 3: Delete the annotation ──────────────────────────────────
    # Dismiss any notification and ensure normal mode
    child.send("\x1b")
    time.sleep(1)

    # Run :AuditDelete command
    slow_send(child, ":AuditDelete\r", delay=0.06)
    time.sleep(2)

    # Confirm deletion with "y"
    child.send("y")
    time.sleep(0.3)
    child.send("\r")
    time.sleep(3)

    # Quit nvim
    child.send("\x1b")
    time.sleep(0.5)
    slow_send(child, ":q!\r", delay=0.06)
    time.sleep(2)

    child.expect(pexpect.EOF, timeout=15)
    child.close()

    print(f"\n\nRecording saved to: {CAST_FILE}")


if __name__ == "__main__":
    main()
