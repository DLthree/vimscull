#!/usr/bin/env python3
"""Drive an nvim session through the search & tags tutorial and record with asciinema.

Shows: connect, add tagged notes across code, NoteSearch, NoteSearchTags, NoteTagCount.
Uses example_flow.py (the request pipeline) as the demo file.
"""

import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import pexpect

DEMO_DIR = Path(__file__).resolve().parent
REPO_ROOT = DEMO_DIR.parent
CAST_FILE = DEMO_DIR / "search-tutorial.cast"
LAUNCH_SCRIPT = DEMO_DIR / "launch_search_nvim.sh"
SETUP_SCRIPT = DEMO_DIR / "setup_demo_server.py"
PORT = 5223


def slow_send(child, text, delay=0.06):
    for ch in text:
        child.send(ch)
        time.sleep(delay)


def enter(child):
    child.send("\r")


def escape(child):
    child.send("\x1b")


def pause(secs=2):
    time.sleep(secs)


def find_python():
    venv = REPO_ROOT / ".venv" / "bin" / "python3"
    if venv.exists():
        return str(venv)
    return "python3"


def main():
    python = find_python()

    # Start mock server with pre-created project
    server_proc = subprocess.Popen(
        [python, str(SETUP_SCRIPT), "--port", str(PORT), "--project", "security-review"],
        stdout=subprocess.PIPE,
        text=True,
    )
    config_dir = server_proc.stdout.readline().strip()
    if not config_dir or not Path(config_dir).is_dir():
        print("ERROR: failed to start mock server", file=sys.stderr)
        server_proc.kill()
        sys.exit(1)
    print(f"Mock server started, config_dir={config_dir}")

    try:
        os.environ["TERM"] = "xterm-256color"
        os.environ["USER"] = "demo-reviewer"
        os.environ["NUMSCULL_CONFIG_DIR"] = config_dir
        os.environ["NUMSCULL_PORT"] = str(PORT)

        child = pexpect.spawn(
            "asciinema",
            ["rec", "--overwrite", "-c", str(LAUNCH_SCRIPT), str(CAST_FILE)],
            encoding="utf-8",
            dimensions=(38, 110),
            timeout=30,
        )

        # Wait for nvim to fully load
        pause(4)

        # -- Connect and set up project --
        escape(child)
        pause(0.5)
        slow_send(child, f":NumscullConnect 127.0.0.1 {PORT}\r", delay=0.05)
        pause(3)

        slow_send(child, ":NumscullProject security-review\r", delay=0.05)
        pause(2)

        # -- Add several tagged notes across the file --
        # Note 1: line 6 — auth validation
        escape(child)
        pause(0.5)
        slow_send(child, ":6\r", delay=0.10)
        pause(1)
        slow_send(child, ":NoteAdd missing rate limiting on auth check #auth #rate-limit\r", delay=0.04)
        pause(3)

        # Note 2: line 16 — token validation
        slow_send(child, ":16\r", delay=0.10)
        pause(1)
        slow_send(child, ":NoteAdd Bearer prefix check insufficient — validate JWT signature #auth #jwt\r", delay=0.04)
        pause(3)

        # Note 3: line 22 — JWT decode
        slow_send(child, ":22\r", delay=0.10)
        pause(1)
        slow_send(child, ":NoteAdd no signature verification on JWT claims #auth #jwt #critical\r", delay=0.04)
        pause(3)

        # Note 4: line 48 — amount validation
        slow_send(child, ":48\r", delay=0.10)
        pause(1)
        slow_send(child, ":NoteAdd no validation on amount sign — allows negative transfers #validation #critical\r", delay=0.04)
        pause(3)

        # -- SCENE: Search by text --
        escape(child)
        pause(0.5)
        slow_send(child, ":NoteSearch validation\r", delay=0.05)
        pause(3)

        # -- SCENE: Search by tag --
        slow_send(child, ":NoteSearchTags critical\r", delay=0.05)
        pause(3)

        slow_send(child, ":NoteSearchTags auth\r", delay=0.05)
        pause(3)

        # -- SCENE: Show tag counts --
        slow_send(child, ":NoteTagCount\r", delay=0.05)
        pause(4)

        # -- SCENE: List notes for the file --
        slow_send(child, ":NoteList\r", delay=0.05)
        pause(4)

        # Close the list
        slow_send(child, ":q\r", delay=0.06)
        pause(1)

        # -- Disconnect and quit --
        escape(child)
        pause(0.5)
        slow_send(child, ":NumscullDisconnect\r", delay=0.05)
        pause(2)

        escape(child)
        pause(0.5)
        slow_send(child, ":q!\r", delay=0.06)
        pause(2)

        child.expect(pexpect.EOF, timeout=15)
        child.close()

        print(f"\n\nRecording saved to: {CAST_FILE}")

    finally:
        server_proc.terminate()
        try:
            server_proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            server_proc.kill()


if __name__ == "__main__":
    main()
