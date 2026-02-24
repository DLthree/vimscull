#!/usr/bin/env python3
"""Record a unified vimscull demo showing all features.

Demonstrates: connect, add notes, list notes, create flow,
add flow nodes (visual selection), show flow, list flows, disconnect.

Replaces the old separate notes/search/flow tutorials.
"""

import os
import subprocess
import sys
import time
from pathlib import Path

import pexpect

from demo_utils import (
    CAST_FILE,
    DEFAULT_PORT,
    INIT_FILE,
    PRE_SETUP_SCRIPT,
    REPO_ROOT,
    SETUP_SCRIPT,
    find_python,
)

PORT = DEFAULT_PORT


# ── pexpect helpers ──────────────────────────────────────────────


def slow_send(child, text, delay=0.06):
    """Type text character-by-character so the screencast looks natural."""
    for ch in text:
        child.send(ch)
        time.sleep(delay)


def escape(child):
    child.send("\x1b")


def pause(secs=2):
    time.sleep(secs)


# ── scenes ───────────────────────────────────────────────────────


def scene_connect(child):
    """Scene 1: Connect to the Numscull server and select a project."""
    escape(child)
    pause(0.5)
    slow_send(child, f":NumscullConnect 127.0.0.1 {PORT}\r", delay=0.05)
    pause(3)
    slow_send(child, ":NumscullProject demo-project\r", delay=0.05)
    pause(2)


def scene_add_notes(child):
    """Scene 2: Add annotations on two different lines."""
    escape(child)
    pause(0.5)
    slow_send(child, ":10\r", delay=0.10)
    pause(1.5)
    slow_send(child, ":NoteAdd Consider using argon2 instead of pbkdf2 #security\r", delay=0.04)
    pause(3)

    escape(child)
    pause(0.5)
    slow_send(child, ":22\r", delay=0.10)
    pause(1.5)
    slow_send(child, ":NoteAdd Check return value for edge cases #bug\r", delay=0.04)
    pause(3)


def scene_list_notes(child):
    """Scene 3: Show the note listing buffer."""
    escape(child)
    pause(0.5)
    slow_send(child, ":NoteList\r", delay=0.05)
    pause(3)
    slow_send(child, ":q\r", delay=0.06)
    pause(1)


def scene_create_flow(child):
    """Scene 4: Create a new audit flow."""
    escape(child)
    pause(0.5)
    slow_send(child, ":FlowCreate Security Audit\r", delay=0.05)
    pause(2)


def scene_add_flow_nodes(child):
    """Scene 5: Add nodes to the flow via visual selection.

    FlowAddNode uses flow.add_node_visual() which prompts for:
      1. color  (vim.ui.select — built-in UI shows numbered list)
      2. note   (vim.ui.input)
    We answer with the item NUMBER, not the name.
    """
    # ── first node: hash_password (line 7) ──
    escape(child)
    pause(0.5)
    slow_send(child, ":7\r", delay=0.10)
    pause(1)
    slow_send(child, "wviw", delay=0.10)       # visual-select word
    pause(1)
    slow_send(child, ":FlowAddNode\r", delay=0.05)
    pause(2)
    child.send("1\r")                           # 1 = Red
    pause(2)
    slow_send(child, "Weak hashing\r", delay=0.04)  # node note
    pause(2)

    # ── second node: verify_password (line 14) ──
    escape(child)
    pause(0.5)
    slow_send(child, ":14\r", delay=0.10)
    pause(1)
    slow_send(child, "wviw", delay=0.10)
    pause(1)
    slow_send(child, ":FlowAddNode\r", delay=0.05)
    pause(2)
    child.send("2\r")                           # 2 = Blue
    pause(2)
    slow_send(child, "Timing side-channel\r", delay=0.04)  # node note
    pause(2)


def scene_show_flow(child):
    """Scene 6: Show the flow detail view with nodes."""
    escape(child)
    pause(0.5)
    slow_send(child, ":FlowShow\r", delay=0.05)
    pause(3)
    slow_send(child, ":q\r", delay=0.06)
    pause(1)


def scene_list_flows(child):
    """Scene 7: Show the flow listing buffer."""
    escape(child)
    pause(0.5)
    slow_send(child, ":FlowList\r", delay=0.05)
    pause(3)
    slow_send(child, ":q\r", delay=0.06)
    pause(1)


def scene_disconnect(child):
    """Scene 8: Disconnect and quit Neovim."""
    escape(child)
    pause(0.5)
    slow_send(child, ":NumscullDisconnect\r", delay=0.05)
    pause(2)
    escape(child)
    pause(0.5)
    slow_send(child, ":q!\r", delay=0.06)
    pause(2)


# ── main ─────────────────────────────────────────────────────────


def main():
    python = find_python()

    # 1. Pre-install plugins
    print("Step 1: Pre-installing Neovim plugins...")
    subprocess.run([python, str(PRE_SETUP_SCRIPT)], check=True)
    print("Done\n")

    # 2. Start mock server with a pre-created project
    print("Step 2: Starting mock server...")
    server_proc = subprocess.Popen(
        [python, str(SETUP_SCRIPT), "--port", str(PORT), "--project", "demo-project"],
        stdout=subprocess.PIPE,
        text=True,
    )
    config_dir = server_proc.stdout.readline().strip()
    if not config_dir or not Path(config_dir).is_dir():
        print("ERROR: failed to start mock server", file=sys.stderr)
        server_proc.kill()
        sys.exit(1)
    print(f"Mock server ready (config_dir={config_dir})\n")

    try:
        os.environ["TERM"] = "xterm-256color"
        os.environ["USER"] = "demo-reviewer"
        os.environ["NUMSCULL_CONFIG_DIR"] = config_dir
        os.environ["NUMSCULL_PORT"] = str(PORT)

        # 3. Record the demo
        print("Step 3: Recording demo...")
        launch_cmd = (
            f"cd {REPO_ROOT} && nvim -u {INIT_FILE} {REPO_ROOT}/demo/example.py"
        )

        child = pexpect.spawn(
            "asciinema",
            ["rec", "--overwrite", "-c", launch_cmd, str(CAST_FILE)],
            encoding="utf-8",
            dimensions=(35, 100),
            timeout=180,
        )

        # Wait for nvim to fully load
        pause(3)

        scene_connect(child)
        scene_add_notes(child)
        scene_list_notes(child)
        scene_create_flow(child)
        scene_add_flow_nodes(child)
        scene_show_flow(child)
        scene_list_flows(child)
        scene_disconnect(child)

        child.expect(pexpect.EOF, timeout=15)
        child.close()

        # 4. Report log file location for debugging
        log_file = Path(config_dir) / "demo.log"
        if log_file.exists():
            print(f"\nDemo log: {log_file}")

        print(f"Recording saved to: {CAST_FILE}")

    finally:
        server_proc.terminate()
        try:
            server_proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            server_proc.kill()


if __name__ == "__main__":
    main()
