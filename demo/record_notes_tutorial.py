#!/usr/bin/env python3
"""Drive an nvim session through the server-connected notes tutorial and record with asciinema.

Shows: connect to Numscull server, create project, add/edit/show/list/toggle/delete notes.
Replaces the old annotation-tutorial that used local-only AuditAdd/AuditEdit/AuditDelete.
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
CAST_FILE = DEMO_DIR / "notes-tutorial.cast"
LAUNCH_SCRIPT = DEMO_DIR / "launch_notes_nvim.sh"
SETUP_SCRIPT = DEMO_DIR / "setup_demo_server.py"
PORT = 5222


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
        [python, str(SETUP_SCRIPT), "--port", str(PORT), "--project", "demo-audit"],
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
            dimensions=(35, 100),
            timeout=120,
        )

        # Wait for nvim to fully load (with lazy.nvim plugin installation)
        pause(15)

        # -- SCENE 1: Connect to server and set up project --
        escape(child)
        pause(0.5)

        slow_send(child, f":NumscullConnect 127.0.0.1 {PORT}\r", delay=0.05)
        pause(3)

        # Switch to pre-created project
        slow_send(child, ":NumscullProject demo-audit\r", delay=0.05)
        pause(2)

        # -- SCENE 2: Add a note --
        # Navigate to line 10 (the pbkdf2 hashing line)
        escape(child)
        pause(0.5)
        slow_send(child, ":10\r", delay=0.10)
        pause(1.5)

        slow_send(child, ":NoteAdd\r", delay=0.05)
        pause(1.5)

        # Type at the input prompt
        slow_send(child, "Consider using argon2 instead of pbkdf2 #security", delay=0.04)
        pause(0.5)
        enter(child)
        pause(3)

        # -- SCENE 3: Show the note --
        escape(child)
        pause(0.5)
        slow_send(child, ":NoteShow\r", delay=0.05)
        pause(3)

        # -- SCENE 4: Edit the note --
        escape(child)
        pause(0.5)
        slow_send(child, ":NoteEdit\r", delay=0.05)
        pause(2)

        # Clear old text and type new
        child.send("\x15")  # Ctrl-U
        pause(0.5)
        slow_send(
            child,
            r"TODO: migrate to argon2id #security #migration\nSee: OWASP password cheatsheet",
            delay=0.04,
        )
        pause(0.5)
        enter(child)
        pause(3)

        # -- SCENE 5: Add a second note on a different line --
        escape(child)
        pause(0.5)
        slow_send(child, ":19\r", delay=0.10)
        pause(1.5)

        slow_send(child, ":NoteAdd timing attack risk in verify comparison #security\r", delay=0.04)
        pause(3)

        # -- SCENE 6: List notes --
        escape(child)
        pause(0.5)
        slow_send(child, ":NoteList\r", delay=0.05)
        pause(4)

        # Close the list
        slow_send(child, ":q\r", delay=0.06)
        pause(1)

        # -- SCENE 7: Toggle visibility --
        escape(child)
        pause(0.5)
        slow_send(child, ":NoteToggle\r", delay=0.05)
        pause(3)

        slow_send(child, ":NoteToggle\r", delay=0.05)
        pause(3)

        # -- SCENE 8: Delete a note --
        escape(child)
        pause(0.5)
        slow_send(child, ":10\r", delay=0.10)
        pause(1)

        slow_send(child, ":NoteDelete\r", delay=0.05)
        pause(2)

        # Confirm deletion
        child.send("y")
        pause(0.3)
        enter(child)
        pause(3)

        # -- SCENE 9: Disconnect --
        escape(child)
        pause(0.5)
        slow_send(child, ":NumscullDisconnect\r", delay=0.05)
        pause(2)

        # Quit nvim
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
