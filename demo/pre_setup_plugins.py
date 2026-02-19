#!/usr/bin/env python3
"""
Pre-setup script to install Neovim plugins before recording demo.
This ensures plugins are installed and nvim doesn't halt waiting for user input.
"""

import subprocess
import sys
import time
from pathlib import Path

DEMO_DIR = Path(__file__).resolve().parent
REPO_ROOT = DEMO_DIR.parent
INIT_FILE = DEMO_DIR / "init_demo.lua"


def main():
    print("Pre-installing Neovim plugins for demo...")
    
    # Change to repo root so the init file can find vimscull
    subprocess.run(["cd", str(REPO_ROOT)], shell=True)
    
    # Run nvim headless to install plugins
    # Use PackerSync or lazy.nvim's sync command
    cmd = [
        "nvim",
        "--headless",
        "-u", str(INIT_FILE),
        "+Lazy! sync",
        "+qall"
    ]
    
    print(f"Running: {' '.join(cmd)}")
    result = subprocess.run(
        cmd,
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        timeout=120
    )
    
    if result.returncode != 0:
        print(f"Warning: Plugin installation returned code {result.returncode}")
        if result.stderr:
            print(f"Stderr: {result.stderr}")
    
    print("✓ Plugins installed")
    
    # Wait a moment
    time.sleep(2)
    
    print("\n✓ Pre-setup complete. Ready to record demo.")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"Error during pre-setup: {e}", file=sys.stderr)
        sys.exit(1)
