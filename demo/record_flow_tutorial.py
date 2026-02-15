#!/usr/bin/env python3
"""Drive an nvim session through the flow tutorial and record with asciinema."""

import os
import sys
import time

import pexpect

DEMO_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(DEMO_DIR)
CAST_FILE = os.path.join(DEMO_DIR, "flow-tutorial.cast")
LAUNCH_SCRIPT = os.path.join(DEMO_DIR, "launch_flow_nvim.sh")

# Clean up any previous flow data so the demo starts fresh
flows_json = os.path.join(REPO_ROOT, ".audit", "flows.json")
if os.path.exists(flows_json):
    os.remove(flows_json)


def slow_send(child, text, delay=0.06):
    """Send text character by character with a delay to simulate typing."""
    for ch in text:
        child.send(ch)
        time.sleep(delay)


def enter(child):
    child.send("\r")


def escape(child):
    child.send("\x1b")


def pause(secs=2):
    time.sleep(secs)


def main():
    os.environ["TERM"] = "xterm-256color"

    child = pexpect.spawn(
        "asciinema",
        ["rec", "--overwrite", "-c", LAUNCH_SCRIPT, CAST_FILE],
        encoding="utf-8",
        dimensions=(38, 110),
        timeout=30,
    )

    # Wait for nvim to fully load
    pause(4)

    # ── SCENE 1: Create a flow and add nodes ─────────────────────────────
    # Create "Security Audit" flow
    escape(child)
    pause(0.5)
    slow_send(child, ":FlowCreate Security Audit\r", delay=0.05)
    pause(2)

    # Node 1: highlight "validate_headers" on line 6 (the guard check)
    # Go to line 6, visually select "validate_headers"
    escape(child)
    pause(0.5)
    slow_send(child, ":6\r", delay=0.10)
    pause(1)
    # Move to column 11 (0-indexed: "    if not " = 11 chars), select the function name
    slow_send(child, "0", delay=0.08)
    pause(0.3)
    slow_send(child, "11l", delay=0.08)
    pause(0.3)
    slow_send(child, "v", delay=0.08)
    slow_send(child, "15l", delay=0.08)  # select "validate_headers"
    pause(0.5)
    # Add node — ESC back to normal, use the command with marks set
    escape(child)
    pause(0.3)
    slow_send(child, ":FlowAddNode\r", delay=0.05)
    pause(1)
    # Pick color 1 = Red
    slow_send(child, "1", delay=0.10)
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
    pause(3)

    # ── SCENE 2: Navigate between nodes ──────────────────────────────────
    # Go to top of file first
    escape(child)
    pause(0.5)
    slow_send(child, "gg", delay=0.10)
    pause(1)

    # FlowNext 3 times to cycle through all nodes
    slow_send(child, ":FlowNext\r", delay=0.05)
    pause(2)
    slow_send(child, ":FlowNext\r", delay=0.05)
    pause(2)
    slow_send(child, ":FlowNext\r", delay=0.05)
    pause(2)

    # FlowPrev to go back
    slow_send(child, ":FlowPrev\r", delay=0.05)
    pause(2)

    # ── SCENE 3: Create a second flow with different nodes ───────────────
    escape(child)
    pause(0.5)
    slow_send(child, ":FlowCreate Bug: Negative Transfer\r", delay=0.05)
    pause(2)

    # Node 1: highlight "amount" on line 43 (process_transfer)
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
    pause(2)

    # Node 2: highlight "amount" on line 49 (execute_transfer — no validation)
    slow_send(child, ":49\r", delay=0.10)
    pause(1)
    slow_send(child, "0", delay=0.08)
    pause(0.3)
    slow_send(child, "4l", delay=0.08)
    pause(0.3)
    slow_send(child, "v", delay=0.08)
    slow_send(child, "55l", delay=0.08)  # select the comment
    pause(0.5)
    escape(child)
    pause(0.3)
    slow_send(child, ":FlowAddNode\r", delay=0.05)
    pause(1)
    slow_send(child, "1", delay=0.10)  # Red
    enter(child)
    pause(3)

    # ── SCENE 4: Switch between flows with FlowSelect ────────────────────
    escape(child)
    pause(0.5)
    slow_send(child, ":FlowSelect\r", delay=0.05)
    pause(3)

    # Press 1 to switch to "Security Audit"
    child.send("1")
    pause(3)

    # Open FlowSelect again and switch back to "Bug: Negative Transfer"
    slow_send(child, ":FlowSelect\r", delay=0.05)
    pause(3)
    child.send("2")
    pause(3)

    # ── SCENE 5: List nodes in the active flow ───────────────────────────
    escape(child)
    pause(0.5)
    slow_send(child, ":FlowList\r", delay=0.05)
    pause(4)

    # Close the list and quit
    slow_send(child, ":q\r", delay=0.06)
    pause(1)

    # Quit nvim
    escape(child)
    pause(0.5)
    slow_send(child, ":q!\r", delay=0.06)
    pause(2)

    child.expect(pexpect.EOF, timeout=15)
    child.close()

    print(f"\n\nRecording saved to: {CAST_FILE}")


if __name__ == "__main__":
    main()
