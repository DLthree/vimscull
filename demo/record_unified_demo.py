#!/usr/bin/env python3
"""
Record a unified vimscull demo showing all features:
- Connect to server
- Add and edit notes (with float editor)
- Add flows and nodes
- List flows

This replaces the separate notes, search, and flow tutorials.
"""

import os
import subprocess
import sys
import time
from pathlib import Path

import pexpect

DEMO_DIR = Path(__file__).resolve().parent
REPO_ROOT = DEMO_DIR.parent
CAST_FILE = DEMO_DIR / "vimscull-demo.cast"
INIT_FILE = DEMO_DIR / "init_demo.lua"
SETUP_SCRIPT = DEMO_DIR / "setup_demo_server.py"
PRE_SETUP_SCRIPT = DEMO_DIR / "pre_setup_plugins.py"
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
    
    # Pre-install plugins
    print("Step 1: Pre-installing Neovim plugins...")
    subprocess.run([python, str(PRE_SETUP_SCRIPT)], check=True)
    print("✓ Plugins installed\n")
    
    # Start mock server with pre-created project
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
    print(f"✓ Mock server started, config_dir={config_dir}\n")
    
    try:
        os.environ["TERM"] = "xterm-256color"
        os.environ["USER"] = "demo-reviewer"
        os.environ["NUMSCULL_CONFIG_DIR"] = config_dir
        os.environ["NUMSCULL_PORT"] = str(PORT)
        
        print("Step 3: Recording demo...")
        
        # Launch nvim with asciinema
        launch_cmd = f"cd {REPO_ROOT} && nvim -u {INIT_FILE} {REPO_ROOT}/demo/example.py"
        
        child = pexpect.spawn(
            "asciinema",
            ["rec", "--overwrite", "-c", launch_cmd, str(CAST_FILE)],
            encoding="utf-8",
            dimensions=(35, 100),
            timeout=180,
        )
        
        # Wait for nvim to fully load (plugins already installed)
        pause(3)
        
        # === SCENE 1: Connect to server ===
        escape(child)
        pause(0.5)
        
        slow_send(child, f":NumscullConnect 127.0.0.1 {PORT}\r", delay=0.05)
        pause(3)
        
        slow_send(child, ":NumscullProject demo-project\r", delay=0.05)
        pause(2)
        
        # === SCENE 2: Add notes ===
        escape(child)
        pause(0.5)
        slow_send(child, ":10\r", delay=0.10)  # Go to line 10
        pause(1.5)
        
        # Add first note with text as argument (no prompt)
        slow_send(child, ":NoteAdd Consider using argon2 instead of pbkdf2 #security\r", delay=0.04)
        pause(3)
        
        # Add second note on another line
        escape(child)
        pause(0.5)
        slow_send(child, ":22\r", delay=0.10)  # Go to line 22
        pause(1.5)
        slow_send(child, ":NoteAdd Check return value for edge cases #bug\r", delay=0.04)
        pause(3)
        
        # === SCENE 3: List notes ===
        escape(child)
        pause(0.5)
        slow_send(child, ":NoteList\r", delay=0.05)
        pause(3)
        
        slow_send(child, ":q\r", delay=0.06)
        pause(1)
        
        # === SCENE 4: Create a flow ===
        escape(child)
        pause(0.5)
        slow_send(child, ":FlowCreate Security Audit\r", delay=0.05)
        pause(2)
        
        # === SCENE 5: Add nodes to flow with visual selection ===
        # Select hash_password function name
        escape(child)
        pause(0.5)
        slow_send(child, ":7\r", delay=0.10)  # Go to line 7
        pause(1)
        slow_send(child, "wviw", delay=0.10)  # Select word
        pause(1)
        slow_send(child, ":FlowAddNode\r", delay=0.05)
        pause(2)
        
        # Select color
        slow_send(child, "Red\r", delay=0.05)
        pause(2)
        
        # Add another node
        escape(child)
        pause(0.5)
        slow_send(child, ":14\r", delay=0.10)  # Line 14
        pause(1)
        slow_send(child, "wviw", delay=0.10)
        pause(1)
        slow_send(child, ":FlowAddNode\r", delay=0.05)
        pause(2)
        slow_send(child, "Blue\r", delay=0.05)
        pause(2)
        
        # === SCENE 6: List flows ===
        escape(child)
        pause(0.5)
        slow_send(child, ":FlowList\r", delay=0.05)
        pause(3)
        
        slow_send(child, ":q\r", delay=0.06)
        pause(1)
        
        # === SCENE 8: Disconnect and quit ===
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
        
        print(f"\n✓ Recording saved to: {CAST_FILE}")
        
    finally:
        server_proc.terminate()
        try:
            server_proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            server_proc.kill()


if __name__ == "__main__":
    main()
