#!/usr/bin/env python3
"""Pre-install Neovim plugins and check system dependencies before recording.

Run this once (or whenever plugins change) so that the demo recording doesn't
stall waiting for interactive prompts.
"""

import subprocess
import sys
import time
from pathlib import Path

from demo_utils import INIT_FILE, REPO_ROOT


def _cmd_available(cmd):
    """Return True if *cmd* is on PATH and responds to --version."""
    try:
        subprocess.run([cmd, "--version"], capture_output=True, check=True)
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


def _module_available(name):
    """Return True if a Python module can be imported."""
    try:
        __import__(name)
        return True
    except ImportError:
        return False


def check_dependencies():
    """Validate that every required tool and library is present."""
    missing = []

    if not _cmd_available("nvim"):
        missing.append("neovim  (sudo apt-get install -y neovim)")

    if not _module_available("nacl"):
        missing.append("pynacl  (pip install pynacl)")

    try:
        import ctypes
        ctypes.CDLL("libsodium.so")
    except OSError:
        missing.append("libsodium-dev  (sudo apt-get install -y libsodium-dev)")

    if not _cmd_available("asciinema"):
        missing.append("asciinema  (pip install asciinema)")

    if missing:
        print("Missing dependencies:")
        for dep in missing:
            print(f"  - {dep}")
        print("\nSee demo/BUILD.md for full instructions.")
        sys.exit(1)

    print("All dependencies present")


def install_plugins():
    """Run nvim headless to let lazy.nvim sync all plugins."""
    cmd = [
        "nvim", "--headless",
        "-u", str(INIT_FILE),
        "+Lazy! sync",
        "+qall",
    ]
    print(f"Running: {' '.join(cmd)}")
    result = subprocess.run(cmd, cwd=str(REPO_ROOT), capture_output=True, text=True, timeout=120)
    if result.returncode != 0:
        print(f"Warning: plugin install returned code {result.returncode}")
        if result.stderr:
            print(f"stderr: {result.stderr[:500]}")

    # Give lazy.nvim a moment to flush
    time.sleep(2)
    print("Plugins installed")


def main():
    check_dependencies()
    install_plugins()
    print("\nPre-setup complete.  Ready to record.")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"Error during pre-setup: {e}", file=sys.stderr)
        sys.exit(1)
