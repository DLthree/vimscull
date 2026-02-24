"""Shared utilities for demo scripts."""

from pathlib import Path

DEMO_DIR = Path(__file__).resolve().parent
REPO_ROOT = DEMO_DIR.parent

# Paths
CAST_FILE = DEMO_DIR / "vimscull-demo.cast"
SVG_FILE = DEMO_DIR / "vimscull-demo.svg"
INIT_FILE = DEMO_DIR / "init_demo.lua"
SETUP_SCRIPT = DEMO_DIR / "setup_demo_server.py"
PRE_SETUP_SCRIPT = DEMO_DIR / "pre_setup_plugins.py"
MOCK_SERVER = REPO_ROOT / "tests" / "mock_server.py"

# Numscull protocol constants
DEFAULT_PORT = 5222
IDENTITY = "demo-reviewer"
HEADER_SIZE = 10
BLOCK_SIZE = 512
NONCE_LEN = 24
KEY_LEN = 32
TAG_LEN = 16
ENCRYPTED_BLOCK_SIZE = BLOCK_SIZE + TAG_LEN


def find_python() -> str:
    """Return the path to the best available Python 3 interpreter."""
    venv = REPO_ROOT / ".venv" / "bin" / "python3"
    if venv.exists():
        return str(venv)
    return "python3"
