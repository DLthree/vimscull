#!/usr/bin/env python3
"""Drive an nvim session through the server-connected flows tutorial and record with asciinema.

Shows: connect to Numscull server, create/navigate/select/list flows, add nodes
with color highlighting, switch between flows, show flow details.
"""

import os
import subprocess
import sys
import time
from pathlib import Path

import pexpect

DEMO_DIR = Path(__file__).resolve().parent
REPO_ROOT = DEMO_DIR.parent
CAST_FILE = DEMO_DIR / "flow-tutorial.cast"
LAUNCH_SCRIPT = DEMO_DIR / "launch_flow_nvim.sh"
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
            dimensions=(38, 110),
            timeout=120,
        )

        # Wait for nvim to fully load (with lazy.nvim plugin installation)
        pause(15)

        # -- SCENE 1: Connect to server and set up project --
        escape(child)
        pause(0.5)

        slow_send(child, f":NumscullConnect 127.0.0.1 {PORT}\r", delay=0.05)
        pause(3)

        slow_send(child, ":NumscullProject demo-audit\r", delay=0.05)
        pause(2)

        # -- SCENE 2: Create "Security Audit" flow --
        escape(child)
        pause(0.5)
        slow_send(child, ":FlowCreate Security Audit\r", delay=0.05)
        pause(2)

        # -- SCENE 3: Add nodes with visual selection --
        # Node 1: highlight "validate_headers" on line 6 (the guard check)
        escape(child)
        pause(0.5)
        slow_send(child, ":6\r", delay=0.10)
        pause(1)
        slow_send(child, "0", delay=0.08)
        pause(0.3)
        slow_send(child, "11l", delay=0.08)
        pause(0.3)
        slow_send(child, "v", delay=0.08)
        slow_send(child, "15l", delay=0.08)  # select "validate_headers"
        pause(0.5)
        escape(child)
        pause(0.3)
        slow_send(child, ":FlowAddNode\r", delay=0.05)
        pause(1)
        # Pick color 1 = Red
        slow_send(child, "1", delay=0.10)
        enter(child)
        pause(1)
        # Enter note
        slow_send(child, "auth guard check", delay=0.05)
        enter(child)
        pause(2)

        # Node 2: highlight "extract_user" on line 9
        slow_send(child, ":9\r", delay=0.10)
        pause(1)
        slow_send(child, "0", delay=0.08)
        pause(0.3)
        slow_send(child, "11l", delay=0.08)
        pause(0.3)
        slow_send(child, "v", delay=0.08)
        slow_send(child, "11l", delay=0.08)  # select "extract_user"
        pause(0.5)
        escape(child)
        pause(0.3)
        slow_send(child, ":FlowAddNode\r", delay=0.05)
        pause(1)
        slow_send(child, "2", delay=0.10)  # Blue
        enter(child)
        pause(1)
        slow_send(child, "JWT extraction", delay=0.05)
        enter(child)
        pause(2)

        # Node 3: highlight "dispatch" on line 11
        slow_send(child, ":11\r", delay=0.10)
        pause(1)
        slow_send(child, "0", delay=0.08)
        pause(0.3)
        slow_send(child, "11l", delay=0.08)
        pause(0.3)
        slow_send(child, "v", delay=0.08)
        slow_send(child, "7l", delay=0.08)  # select "dispatch"
        pause(0.5)
        escape(child)
        pause(0.3)
        slow_send(child, ":FlowAddNode\r", delay=0.05)
        pause(1)
        slow_send(child, "3", delay=0.10)  # Green
        enter(child)
        pause(1)
        slow_send(child, "route to handler", delay=0.05)
        enter(child)
        pause(3)

        # -- SCENE 4: Navigate between nodes --
        escape(child)
        pause(0.5)
        slow_send(child, "gg", delay=0.10)
        pause(1)

        slow_send(child, ":FlowNext\r", delay=0.05)
        pause(2)
        slow_send(child, ":FlowNext\r", delay=0.05)
        pause(2)
        slow_send(child, ":FlowNext\r", delay=0.05)
        pause(2)

        slow_send(child, ":FlowPrev\r", delay=0.05)
        pause(2)

        # -- SCENE 5: Create second flow --
        escape(child)
        pause(0.5)
        slow_send(child, ":FlowCreate Bug: Negative Transfer\r", delay=0.05)
        pause(2)

        # Node 1: highlight "amount" on line 43
        slow_send(child, ":43\r", delay=0.10)
        pause(1)
        slow_send(child, "0", delay=0.08)
        pause(0.3)
        slow_send(child, "14l", delay=0.08)
        pause(0.3)
        slow_send(child, "v", delay=0.08)
        slow_send(child, "5l", delay=0.08)  # select "amount"
        pause(0.5)
        escape(child)
        pause(0.3)
        slow_send(child, ":FlowAddNode\r", delay=0.05)
        pause(1)
        slow_send(child, "4", delay=0.10)  # Yellow
        enter(child)
        pause(1)
        slow_send(child, "amount not validated", delay=0.05)
        enter(child)
        pause(2)

        # Node 2: line 49 — the dangerous comment
        slow_send(child, ":49\r", delay=0.10)
        pause(1)
        slow_send(child, "0", delay=0.08)
        pause(0.3)
        slow_send(child, "4l", delay=0.08)
        pause(0.3)
        slow_send(child, "v", delay=0.08)
        slow_send(child, "55l", delay=0.08)
        pause(0.5)
        escape(child)
        pause(0.3)
        slow_send(child, ":FlowAddNode\r", delay=0.05)
        pause(1)
        slow_send(child, "1", delay=0.10)  # Red
        enter(child)
        pause(1)
        slow_send(child, "BUG: no sign check on amount", delay=0.05)
        enter(child)
        pause(3)

        # -- SCENE 6: Switch between flows with FlowSelect --
        escape(child)
        pause(0.5)
        slow_send(child, ":FlowSelect\r", delay=0.05)
        pause(3)

        # Press 1 to switch to "Security Audit"
        child.send("1")
        pause(3)

        # Open FlowSelect again and switch back
        slow_send(child, ":FlowSelect\r", delay=0.05)
        pause(3)
        child.send("2")
        pause(3)

        # -- SCENE 7: List all flows --
        escape(child)
        pause(0.5)
        slow_send(child, ":FlowList\r", delay=0.05)
        pause(4)

        # Close the list
        slow_send(child, ":q\r", delay=0.06)
        pause(1)

        # -- SCENE 8: Disconnect and quit --
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
