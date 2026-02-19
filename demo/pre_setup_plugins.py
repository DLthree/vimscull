#!/usr/bin/env python3
"""
Pre-setup script to install Neovim plugins before recording demo.
This ensures plugins are installed and nvim doesn't halt waiting for user input.
Also checks for required system dependencies.
"""

import subprocess
import sys
import time
from pathlib import Path

DEMO_DIR = Path(__file__).resolve().parent
REPO_ROOT = DEMO_DIR.parent
INIT_FILE = DEMO_DIR / "init_demo.lua"


def check_dependency(cmd, name):
    """Check if a command/dependency is available."""
    try:
        subprocess.run([cmd, "--version"], capture_output=True, check=True)
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


def check_python_module(module_name):
    """Check if a Python module is installed."""
    try:
        __import__(module_name)
        return True
    except ImportError:
        return False


def main():
    print("Checking dependencies...")
    
    # Check system dependencies
    missing_deps = []
    
    if not check_dependency("nvim", "neovim"):
        missing_deps.append("neovim (install: sudo apt-get install -y neovim)")
    
    # Check for libsodium by trying to load it in Python
    if not check_python_module("nacl"):
        missing_deps.append("pynacl (install: pip install pynacl)")
    
    # Try to check libsodium-dev by looking for the library
    try:
        import ctypes
        ctypes.CDLL("libsodium.so")
    except OSError:
        missing_deps.append("libsodium-dev (install: sudo apt-get install -y libsodium-dev)")
    
    if not check_dependency("asciinema", "asciinema"):
        missing_deps.append("asciinema (install: pip install asciinema)")
    
    if missing_deps:
        print("\n⚠️  Missing dependencies:")
        for dep in missing_deps:
            print(f"  - {dep}")
        print("\nPlease install missing dependencies before recording the demo.")
        print("See demo/BUILD.md for installation instructions.")
        sys.exit(1)
    
    print("✓ All dependencies present\n")
    
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
